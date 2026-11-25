import Foundation
import NIOConcurrencyHelpers

/// Streams `agy` models through the user's local Antigravity CLI over ACP
/// (see ``AgyLocal``).
///
/// One kwwk turn is one ACP `session/prompt`:
///   - `agent_message_chunk` / `agent_thought_chunk` updates stream as text
///     and thinking;
///   - each call agy makes to a kwwk tool arrives on the loopback MCP route,
///     runs inline through `StreamOptions.cursorExecBridge`, and shows up as
///     a `toolCall` block marked `cursorExecResolved` (the agent loop pairs
///     it with the result instead of running it again);
///   - agy's built-in tools are refused at the permission prompt (only
///     `mcp_kwwk_*` is allowed), and each session runs in an empty
///     placeholder workspace so agy's auto-approved reads find nothing.
///
/// Sessions persist per `StreamOptions.sessionId`. A turn whose transcript
/// extends what the session saw sends only the new input; anything else
/// (compaction, edits, a turn by another provider, a changed system prompt
/// or tool list) opens a fresh session seeded with a replay of the
/// transcript.
public final class AgyLocalProvider: APIProvider, APIProviderSessionLifecycle, Sendable {
    public let api: String
    let executable: URL

    public init(executable: URL, api: String = AgyLocal.registryAPI) {
        self.executable = executable
        self.api = api
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        let out = AssistantMessageStream()
        let runtime = AgyLocalRuntime.shared(for: executable)
        Task.detached { [api] in
            await Self.run(api: api, runtime: runtime, out: out, model: model, context: context, options: options)
        }
        return out
    }

    public func closeSession(sessionId: String) async {
        await AgyLocalRuntime.shared(for: executable).closeConversation(key: sessionId)
    }

    // MARK: - Turn

    private static func run(
        api: String,
        runtime: AgyLocalRuntime,
        out: AssistantMessageStream,
        model: Model,
        context: Context,
        options: StreamOptions?
    ) async {
        let state = AgyLocalStreamState(api: api, model: model)
        let emit: @Sendable (AssistantMessageEvent) -> Void = { out.push($0) }
        out.push(.start(partial: state.snapshot()))

        let key = options?.sessionId.flatMap { $0.isEmpty ? nil : $0 }
        let imagesSupported = model.input.contains(.image)
        let bridge = options?.cursorExecBridge
        var lease: AgyLocalRuntime.Lease?
        var cancelRegistration: CancellationRegistration?
        do {
            if options?.cancellation?.isCancelled == true { throw CancellationError() }
            let acquired = try await runtime.acquire(
                key: key,
                context: context,
                model: model,
                cwd: bridge?.cwd,
                imagesSupported: imagesSupported
            )
            lease = acquired
            let client = acquired.client
            let sessionId = acquired.sessionId

            client.setSessionHandler(sessionId) { update in
                Self.apply(update: update, state: state, emit: emit, options: options)
            }
            runtime.server.updateHandler(acquired.routeToken) { name, arguments in
                guard let bridge else {
                    return .init(
                        content: [AgyLocalTranscript.text("kwwk cannot run tools in this context.")],
                        isError: true
                    )
                }
                let callId = "agy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                state.addResolvedToolCall(id: callId, name: name, arguments: arguments, emit: emit)
                let result = await bridge.execute(
                    ToolCall(id: callId, name: name, arguments: arguments, cursorExecResolved: true)
                )
                return .init(
                    content: AgyLocalTranscript.mcpContent(result, imagesSupported: imagesSupported),
                    isError: result.isError
                )
            }
            cancelRegistration = options?.cancellation?.onCancel { _ in
                client.notify("session/cancel", params: ["sessionId": .string(sessionId)])
            }

            let result = try await client.request("session/prompt", params: [
                "sessionId": .string(sessionId),
                "prompt": .array(acquired.prompt),
            ])
            cancelRegistration?.cancel()
            cancelRegistration = nil
            client.setSessionHandler(sessionId, nil)
            runtime.server.updateHandler(acquired.routeToken, AgyLocalRuntime.idleHandler)

            state.closeOpenBlocks(emit: emit)
            if case .object(let usage)? = result["usage"] {
                state.setUsage(
                    input: usage["inputTokens"]?.intValue ?? 0,
                    output: usage["outputTokens"]?.intValue ?? 0,
                    cacheRead: usage["cachedReadTokens"]?.intValue ?? 0,
                    cacheWrite: usage["cachedWriteTokens"]?.intValue ?? 0,
                    reasoning: usage["thoughtTokens"]?.intValue ?? 0
                )
            }
            let stopReason = result["stopReason"]?.stringValue ?? "end_turn"
            let responseId = "agy-acp-" + UUID().uuidString.lowercased()
            state.setResponseId(responseId)

            switch stopReason {
            case "cancelled":
                await runtime.release(acquired, checkpoint: nil)
                let message = state.aborted()
                out.push(.error(reason: .aborted, error: message))
                out.end(message)
            case "refusal":
                await runtime.release(acquired, checkpoint: nil)
                let message = state.failed(ProviderFailure(
                    message: "Antigravity refused to continue this conversation",
                    rawStopReason: stopReason
                ))
                out.push(.error(reason: .error, error: message))
                out.end(message)
            default:
                state.setStopReason(stopReason == "max_tokens" ? .length : .stop)
                await runtime.release(acquired, checkpoint: .init(
                    consumedCount: context.messages.count,
                    consumedDigest: AgyLocalTranscript.digest(context.messages),
                    responseId: responseId,
                    setupDigest: AgyLocalTranscript.setupDigest(context, cwd: bridge?.cwd)
                ))
                let message = state.finalize()
                out.push(.done(reason: message.stopReason, message: message))
                out.end(message)
            }
        } catch {
            cancelRegistration?.cancel()
            if let lease {
                lease.client.setSessionHandler(lease.sessionId, nil)
                runtime.server.updateHandler(lease.routeToken, AgyLocalRuntime.idleHandler)
                await runtime.release(lease, checkpoint: nil)
            }
            state.closeOpenBlocks(emit: emit)
            if error is CancellationError || options?.cancellation?.isCancelled == true {
                let message = state.aborted()
                out.push(.error(reason: .aborted, error: message))
                out.end(message)
                return
            }
            let message = state.failed(Self.failure(for: error, runtime: runtime))
            out.push(.error(reason: .error, error: message))
            out.end(message)
        }
    }

    /// Route one `session/update` into the stream.
    static func apply(
        update: JSONValue,
        state: AgyLocalStreamState,
        emit: (AssistantMessageEvent) -> Void,
        options: StreamOptions?
    ) {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let text = update["content"]?["text"]?.stringValue, !text.isEmpty {
                state.appendText(text, emit: emit)
            }
        case "agent_thought_chunk":
            if let text = update["content"]?["text"]?.stringValue, !text.isEmpty {
                state.appendThinking(text, emit: emit)
            }
        case "tool_call", "tool_call_update":
            // kwwk's own tools surface through the MCP route. A built-in
            // agy tool that ran anyway (one agy does not ask about) is only
            // worth a diagnostic: its output never reaches kwwk.
            let name = update["name"]?.stringValue ?? update["title"]?.stringValue ?? "?"
            guard !name.hasPrefix(AgyLocal.mcpToolPrefix),
                  update["status"]?.stringValue == "completed",
                  options?.verbose == true else { return }
            Task {
                await options?.emitVerbose(
                    source: "agy-local",
                    message: "agy ran its built-in tool \(name) outside kwwk"
                )
            }
        default:
            break
        }
    }

    static func failure(for error: Error, runtime: AgyLocalRuntime) -> ProviderFailure {
        let text = (error as? ACPError)?.message ?? error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("auth") || lower.contains("login") || lower.contains("sign in") || lower.contains("credential") {
            return ProviderFailure(
                message: "Local Antigravity CLI is not signed in (\(text)). Run `agy` in a terminal, sign in, then retry.",
                shouldRetry: false
            )
        }
        return ProviderFailure(message: "Local Antigravity CLI: \(text)", shouldRetry: false)
    }

    /// The answer to agy's `session/request_permission`: allow kwwk's MCP
    /// tools once, refuse everything else once.
    static func permissionOutcome(_ params: JSONValue) -> JSONValue {
        let call = params["toolCall"]
        let name = call?["name"]?.stringValue ?? call?["title"]?.stringValue ?? ""
        let ours = name.hasPrefix(AgyLocal.mcpToolPrefix)
        let options = params["options"]?.arrayValue ?? []
        let wanted = ours ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        let fallbackIds = ours ? ["allow"] : ["deny", "reject"]
        let pick = wanted.lazy.compactMap { kind in
            options.first { $0["kind"]?.stringValue == kind }
        }.first ?? options.first { option in
            fallbackIds.contains(option["optionId"]?.stringValue ?? "")
        }
        guard let optionId = pick?["optionId"] else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        return ["outcome": ["outcome": "selected", "optionId": optionId]]
    }
}

// MARK: - Runtime

/// Process-wide state for one `agy` executable: the `agy acp` process, the
/// MCP bridge server, and the ACP session behind each kwwk conversation.
actor AgyLocalRuntime {
    struct Lease: Sendable {
        let key: String
        let client: ACPClient
        let sessionId: String
        let routeToken: String
        let prompt: [JSONValue]
        let ephemeral: Bool
    }

    private struct Conversation {
        var sessionId: String
        var routeToken: String
        var modelSlug: String
        var checkpoint: AgyLocalTranscript.Checkpoint?
        var busy: Bool
    }

    private static let runtimes = NIOLockedValueBox([String: AgyLocalRuntime]())

    static func shared(for executable: URL) -> AgyLocalRuntime {
        runtimes.withLockedValue { runtimes in
            if let existing = runtimes[executable.path] { return existing }
            let runtime = AgyLocalRuntime(executable: executable)
            runtimes[executable.path] = runtime
            return runtime
        }
    }

    static let idleHandler: AgyMCPBridgeServer.CallHandler = { _, _ in
        .init(content: [AgyLocalTranscript.text("No kwwk turn is active for this session.")], isError: true)
    }

    let executable: URL
    let server = AgyMCPBridgeServer()
    /// Placeholder workspace root: agy's cwd and every session's `cwd` live
    /// under it, empty, so agy's auto-approved file reads find nothing.
    let workspaceRoot: URL
    private var client: ACPClient?
    private var starting: Task<ACPClient, Error>?
    private var conversations: [String: Conversation] = [:]
    /// ACP sessions opened so far (tests check that turns reuse one).
    private(set) var sessionsOpened = 0

    init(executable: URL) {
        self.executable = executable
        self.workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-agy-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    // MARK: Connection

    private func connectedClient() async throws -> ACPClient {
        if let client, client.isAlive { return client }
        if let starting { return try await starting.value }
        // A dead agy took every session with it.
        for conversation in conversations.values {
            server.setRoute(conversation.routeToken, nil)
        }
        conversations.removeAll()
        let executable = executable
        let root = workspaceRoot
        let server = server
        let task = Task<ACPClient, Error> {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await server.start()
            let client = ACPClient { method, params in
                guard method == "session/request_permission" else {
                    return .failure(ACPError("method not found: \(method)", code: -32601))
                }
                return .success(AgyLocalProvider.permissionOutcome(params))
            }
            do {
                try await client.start(executable: executable, cwd: root)
            } catch {
                client.close()
                throw error
            }
            return client
        }
        starting = task
        defer { starting = nil }
        let connected = try await task.value
        client = connected
        return connected
    }

    // MARK: Conversations

    /// Reserve the ACP session for this turn, opening one when needed, and
    /// return it with the prompt to send.
    func acquire(
        key: String?,
        context: Context,
        model: Model,
        cwd: String?,
        imagesSupported: Bool
    ) async throws -> Lease {
        let client = try await connectedClient()
        let slug = AgyLocal.slug(for: model.id)

        // A kwwk session with a turn already in flight (or none at all) gets
        // a one-turn session of its own.
        var conversationKey = key ?? "ephemeral-\(UUID().uuidString)"
        var ephemeral = key == nil
        if let key, conversations[key]?.busy == true {
            conversationKey = "\(key)#\(UUID().uuidString)"
            ephemeral = true
        }

        let existing = conversations[conversationKey]
        let plan = AgyLocalTranscript.plan(
            context: context,
            cwd: cwd,
            checkpoint: existing?.checkpoint,
            imagesSupported: imagesSupported
        )

        if var conversation = existing, case .continueSession = plan {
            conversation.busy = true
            conversations[conversationKey] = conversation
            if conversation.modelSlug != slug {
                do {
                    _ = try await client.request("session/set_model", params: [
                        "sessionId": .string(conversation.sessionId),
                        "modelId": .string(slug),
                    ], timeout: 30)
                    conversations[conversationKey]?.modelSlug = slug
                } catch {
                    conversations[conversationKey]?.busy = false
                    throw error
                }
            }
            return Lease(
                key: conversationKey,
                client: client,
                sessionId: conversation.sessionId,
                routeToken: conversation.routeToken,
                prompt: plan.prompt,
                ephemeral: ephemeral
            )
        }

        if let existing {
            dispose(existing, client: client)
            conversations[conversationKey] = nil
        }
        let routeToken = AgyMCPBridgeServer.randomToken()
        let tools = context.tools ?? []
        server.setRoute(routeToken, .init(tools: tools, onCall: Self.idleHandler))
        do {
            var mcpServers: [JSONValue] = []
            if !tools.isEmpty, let url = server.url(for: routeToken) {
                mcpServers.append([
                    "type": "http",
                    "name": .string(AgyLocal.mcpServerName),
                    "url": .string(url),
                    "headers": [["name": "authorization", "value": .string("Bearer \(server.secret)")]],
                ])
            }
            let created = try await client.request("session/new", params: [
                "cwd": .string(workspaceRoot.path),
                "mcpServers": .array(mcpServers),
                "_meta": ["antigravity": ["systemPrompt": [
                    "append": .string(AgyLocalTranscript.systemPromptAppendix(context, cwd: cwd)),
                ]]],
            ], timeout: 60)
            guard let sessionId = created["sessionId"]?.stringValue else {
                throw ACPError("agy acp did not return a session id")
            }
            sessionsOpened += 1
            conversations[conversationKey] = Conversation(
                sessionId: sessionId,
                routeToken: routeToken,
                modelSlug: slug,
                checkpoint: nil,
                busy: true
            )
            if created["models"]?["currentModelId"]?.stringValue != slug {
                _ = try await client.request("session/set_model", params: [
                    "sessionId": .string(sessionId),
                    "modelId": .string(slug),
                ], timeout: 30)
            }
            return Lease(
                key: conversationKey,
                client: client,
                sessionId: sessionId,
                routeToken: routeToken,
                prompt: plan.prompt,
                ephemeral: ephemeral
            )
        } catch {
            if let conversation = conversations.removeValue(forKey: conversationKey) {
                dispose(conversation, client: client)
            } else {
                server.setRoute(routeToken, nil)
            }
            throw error
        }
    }

    /// End a turn. `checkpoint` records what the session saw so the next
    /// turn can continue it; nil (an error, a cancel) retires the session.
    func release(_ lease: Lease, checkpoint: AgyLocalTranscript.Checkpoint?) {
        guard var conversation = conversations[lease.key], conversation.sessionId == lease.sessionId else { return }
        if lease.ephemeral || checkpoint == nil {
            conversations[lease.key] = nil
            dispose(conversation, client: lease.client)
            return
        }
        conversation.checkpoint = checkpoint
        conversation.busy = false
        conversations[lease.key] = conversation
    }

    func closeConversation(key: String) {
        let matching = conversations.filter { $0.key == key || $0.key.hasPrefix("\(key)#") }
        for (conversationKey, conversation) in matching {
            conversations[conversationKey] = nil
            if let client { dispose(conversation, client: client) }
        }
    }

    private func dispose(_ conversation: Conversation, client: ACPClient) {
        server.setRoute(conversation.routeToken, nil)
        client.setSessionHandler(conversation.sessionId, nil)
        let sessionId = conversation.sessionId
        Task {
            _ = try? await client.request("session/close", params: ["sessionId": .string(sessionId)], timeout: 30)
        }
    }
}

// MARK: - Stream state

/// Accumulates the assistant message for one turn and emits its events.
/// Text and thinking run as sequential blocks (opening one closes the
/// other); a tool call closes both.
final class AgyLocalStreamState: Sendable {
    private struct State {
        var blocks: [AssistantBlock] = []
        var openText: Int?
        var openThinking: Int?
        var usage = Usage()
        var stopReason: StopReason = .stop
        var responseId: String?
    }

    private let api: String
    private let model: Model
    private let state = NIOLockedValueBox(State())

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    /// A block opens empty: its `*Start` event's partial must not already
    /// hold the first delta, or a consumer that reads the snapshot at the
    /// start and then appends the delta (the TUI transcript does) sees that
    /// text twice.
    func appendText(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        endThinking(emit: emit)
        let opened = state.withLockedValue { state -> Int? in
            guard state.openText == nil else { return nil }
            state.blocks.append(.text(TextContent(text: "")))
            state.openText = state.blocks.count - 1
            return state.openText
        }
        if let opened { emit(.textStart(contentIndex: opened, partial: snapshot())) }
        let index = state.withLockedValue { state -> Int in
            let index = state.openText!
            if case .text(var t) = state.blocks[index] {
                t.text += delta
                state.blocks[index] = .text(t)
            }
            return index
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func appendThinking(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        let opened = state.withLockedValue { state -> Int? in
            guard state.openThinking == nil else { return nil }
            state.blocks.append(.thinking(ThinkingContent(thinking: "")))
            state.openThinking = state.blocks.count - 1
            return state.openThinking
        }
        if let opened { emit(.thinkingStart(contentIndex: opened, partial: snapshot())) }
        let index = state.withLockedValue { state -> Int in
            let index = state.openThinking!
            if case .thinking(var t) = state.blocks[index] {
                t.thinking += delta
                state.blocks[index] = .thinking(t)
            }
            return index
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    /// Append a `toolCall` block for a call that is about to run inline.
    func addResolvedToolCall(id: String, name: String, arguments: JSONValue, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let call = ToolCall(id: id, name: name, arguments: arguments, cursorExecResolved: true)
        let index = state.withLockedValue { state -> Int in
            state.blocks.append(.toolCall(call))
            return state.blocks.count - 1
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
        emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
    }

    func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed = state.withLockedValue { state -> (Int, String)? in
            guard let index = state.openText, case .text(let t) = state.blocks[index] else { return nil }
            state.openText = nil
            return (index, t.text)
        }
        if let (index, text) = closed {
            emit(.textEnd(contentIndex: index, content: text, partial: snapshot()))
        }
    }

    func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed = state.withLockedValue { state -> (Int, String)? in
            guard let index = state.openThinking, case .thinking(let t) = state.blocks[index] else { return nil }
            state.openThinking = nil
            return (index, t.thinking)
        }
        if let (index, thinking) = closed {
            emit(.thinkingEnd(contentIndex: index, content: thinking, partial: snapshot()))
        }
    }

    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
    }

    /// ACP `usage`: `inputTokens` excludes cache reads (agy reports
    /// `totalTokens = input + output + cachedRead`), matching kwwk's `input`.
    func setUsage(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int) {
        state.withLockedValue { state in
            var usage = Usage(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning
            )
            usage.totalTokens = input + output + cacheRead + cacheWrite
            usage.cost = calculateCost(model: model, usage: usage)
            state.usage = usage
        }
    }

    func setStopReason(_ reason: StopReason) {
        state.withLockedValue { $0.stopReason = reason }
    }

    func setResponseId(_ id: String) {
        state.withLockedValue { $0.responseId = id }
    }

    func snapshot() -> AssistantMessage {
        state.withLockedValue { state in
            AssistantMessage(
                content: state.blocks,
                api: api,
                provider: model.provider,
                model: model.id,
                responseId: state.responseId,
                usage: state.usage,
                stopReason: state.stopReason,
                timestamp: Timestamp.now()
            )
        }
    }

    func finalize() -> AssistantMessage { snapshot() }

    func aborted() -> AssistantMessage {
        setStopReason(.aborted)
        var message = snapshot()
        message.errorMessage = "Request was aborted"
        return message
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        setStopReason(.error)
        var message = snapshot()
        message.errorMessage = failure.message
        message.failure = failure
        return message
    }
}
