import Foundation
import Testing
@testable import KWWKAI

@Suite("Antigravity CLI (agy) local ACP provider")
struct AgyLocalTests {
    // MARK: - Fixtures

    static let tool = Tool(
        name: "read",
        description: "Read a file",
        parameters: ["type": "object", "properties": ["path": ["type": "string"]]]
    )

    static func user(_ text: String, at ts: Int64) -> Message {
        .user(UserMessage(text: text, timestamp: ts))
    }

    static func reply(responseId: String, calls: [ToolCall] = [], text: String = "done") -> Message {
        .assistant(AssistantMessage(
            content: calls.map { .toolCall($0) } + [.text(TextContent(text: text))],
            api: AgyLocal.registryAPI,
            provider: AgyLocal.providerScope,
            model: "gemini-3.8-flash-low",
            responseId: responseId,
            timestamp: 2
        ))
    }

    static func result(for call: ToolCall, _ text: String) -> Message {
        .toolResult(ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            content: [.text(TextContent(text: text))],
            timestamp: 3
        ))
    }

    static func checkpoint(for context: Context, responseId: String, cwd: String? = "/work") -> AgyLocalTranscript.Checkpoint {
        .init(
            consumedCount: context.messages.count,
            consumedDigest: AgyLocalTranscript.digest(context.messages),
            responseId: responseId,
            setupDigest: AgyLocalTranscript.setupDigest(context, cwd: cwd)
        )
    }

    static func texts(_ blocks: [JSONValue]) -> [String] {
        blocks.compactMap { $0["text"]?.stringValue }
    }

    // MARK: - Planning

    @Test("first turn opens a fresh session carrying only the input")
    func firstTurnIsFresh() {
        let context = Context(systemPrompt: "sys", messages: [Self.user("hi", at: 1)], tools: [Self.tool])
        let plan = AgyLocalTranscript.plan(context: context, cwd: "/work", checkpoint: nil, imagesSupported: true)
        #expect(plan == .freshSession(prompt: [AgyLocalTranscript.text("hi")]))
    }

    @Test("a turn extending the checkpointed transcript sends only the new user input")
    func continuationSendsDelta() throws {
        let first = Context(systemPrompt: "sys", messages: [Self.user("read a.txt", at: 1)], tools: [Self.tool])
        let checkpoint = Self.checkpoint(for: first, responseId: "r1")
        let call = ToolCall(id: "agy_1", name: "read", arguments: ["path": "a.txt"], cursorExecResolved: true)
        var next = first
        next.messages += [
            Self.reply(responseId: "r1", calls: [call]),
            Self.result(for: call, "contents"),
            Self.user("and now?", at: 4),
        ]
        let plan = AgyLocalTranscript.plan(context: next, cwd: "/work", checkpoint: checkpoint, imagesSupported: true)
        #expect(plan == .continueSession(prompt: [AgyLocalTranscript.text("and now?")]))
    }

    @Test("an edited prefix, another reply, or a changed setup starts over with a replay")
    func divergenceStartsFresh() {
        let first = Context(systemPrompt: "sys", messages: [Self.user("q1", at: 1)], tools: [Self.tool])
        let checkpoint = Self.checkpoint(for: first, responseId: "r1")
        let continued = first.messages + [Self.reply(responseId: "r1"), Self.user("q2", at: 4)]

        // Prefix rewritten (compaction / edit).
        var edited = first
        edited.messages = [Self.user("q1 edited", at: 1)] + continued.dropFirst()
        // Reply that is not the session's own (another provider answered).
        var foreign = first
        foreign.messages = first.messages + [Self.reply(responseId: "other"), Self.user("q2", at: 4)]
        // System prompt or working directory changed.
        var resystemed = Context(systemPrompt: "new sys", messages: continued, tools: [Self.tool])
        resystemed.tools = [Self.tool]

        for context in [edited, foreign, resystemed] {
            let plan = AgyLocalTranscript.plan(context: context, cwd: "/work", checkpoint: checkpoint, imagesSupported: true)
            guard case .freshSession(let prompt) = plan else {
                Issue.record("expected a fresh session, got \(plan)")
                continue
            }
            #expect(Self.texts(prompt).first?.hasPrefix("<conversation_history>") == true)
            #expect(Self.texts(prompt).last == "q2")
        }
        let movedCwd = Context(systemPrompt: "sys", messages: continued, tools: [Self.tool])
        let plan = AgyLocalTranscript.plan(context: movedCwd, cwd: "/elsewhere", checkpoint: checkpoint, imagesSupported: true)
        guard case .freshSession = plan else {
            Issue.record("a new cwd must reopen the session")
            return
        }
    }

    @Test("history replay lists user text, replies, tool calls and results")
    func historyReplayContents() throws {
        let call = ToolCall(id: "c1", name: "read", arguments: ["path": "a.txt"])
        let messages: [Message] = [
            Self.user("read a.txt", at: 1),
            Self.reply(responseId: "x", calls: [call], text: "reading"),
            Self.result(for: call, "file body"),
        ]
        let replay = try #require(AgyLocalTranscript.historyReplay(messages))
        #expect(replay.contains("[user]\nread a.txt"))
        #expect(replay.contains("[assistant called tool read]\n{\"path\":\"a.txt\"}"))
        #expect(replay.contains("[tool result: read]\nfile body"))
        #expect(replay.contains("[assistant]\nreading"))
        #expect(AgyLocalTranscript.historyReplay([]) == nil)
    }

    @Test("images pass through for vision models and become placeholders otherwise")
    func imagesInInput() {
        let image = ImageContent(data: "AAAA", mimeType: "image/png")
        let messages: [Message] = [.user(UserMessage(content: [.text(TextContent(text: "look")), .image(image)]))]
        let vision = AgyLocalTranscript.inputBlocks(messages, imagesSupported: true)
        #expect(vision.last?["type"]?.stringValue == "image")
        #expect(vision.last?["data"]?.stringValue == "AAAA")
        let textOnly = AgyLocalTranscript.inputBlocks(messages, imagesSupported: false)
        #expect(textOnly.last?["type"]?.stringValue == "text")
        #expect(AgyLocalTranscript.inputBlocks([], imagesSupported: true) == [AgyLocalTranscript.text("Continue.")])
    }

    @Test("the system prompt appendix names the tool server and the real cwd")
    func systemPromptAppendix() {
        let context = Context(systemPrompt: "Be terse.", messages: [], tools: [Self.tool])
        let appendix = AgyLocalTranscript.systemPromptAppendix(context, cwd: "/Users/me/project")
        #expect(appendix.hasPrefix("Be terse."))
        #expect(appendix.contains("mcp_kwwk_"))
        #expect(appendix.contains("`/Users/me/project`"))
    }

    // MARK: - Stream state

    @Test("blocks open empty, so start snapshots plus deltas spell the text exactly once")
    func streamStateOpensBlocksEmpty() {
        let model = AgyLocal.model(id: "gemini-3.8-flash-low")
        let state = AgyLocalStreamState(api: AgyLocal.registryAPI, model: model)
        var events: [AssistantMessageEvent] = []
        state.appendThinking("plan ", emit: { events.append($0) })
        state.appendThinking("it", emit: { events.append($0) })
        state.appendText("Hello ", emit: { events.append($0) })
        state.appendText("world", emit: { events.append($0) })
        state.closeOpenBlocks(emit: { events.append($0) })

        var textDeltas = ""
        var thinkingDeltas = ""
        for event in events {
            switch event {
            case .textStart(let idx, let partial):
                guard case .text(let t) = partial.content[idx] else {
                    Issue.record("textStart index is not a text block")
                    continue
                }
                #expect(t.text.isEmpty)
            case .thinkingStart(let idx, let partial):
                guard case .thinking(let t) = partial.content[idx] else {
                    Issue.record("thinkingStart index is not a thinking block")
                    continue
                }
                #expect(t.thinking.isEmpty)
            case .textDelta(_, let delta, _): textDeltas += delta
            case .thinkingDelta(_, let delta, _): thinkingDeltas += delta
            default: break
            }
        }
        #expect(textDeltas == "Hello world")
        #expect(thinkingDeltas == "plan it")
        let final = state.finalize()
        #expect(final.content == [
            .thinking(ThinkingContent(thinking: "plan it")),
            .text(TextContent(text: "Hello world")),
        ])
    }

    // MARK: - Permissions

    @Test("permission prompts allow kwwk's MCP tools and refuse agy's built-ins")
    func permissionPolicy() {
        let options: JSONValue = [
            ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
            ["optionId": "deny", "name": "Deny", "kind": "reject_once"],
        ]
        let ours = AgyLocalProvider.permissionOutcome([
            "toolCall": ["name": "mcp_kwwk_read"], "options": options,
        ])
        #expect(ours == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        let builtin = AgyLocalProvider.permissionOutcome([
            "toolCall": ["name": "run_command"], "options": options,
        ])
        #expect(builtin == ["outcome": ["outcome": "selected", "optionId": "deny"]])
        let noOptions = AgyLocalProvider.permissionOutcome(["toolCall": ["name": "read_file"]])
        #expect(noOptions == ["outcome": ["outcome": "cancelled"]])
    }

    // MARK: - Discovery

    @Test("discovery honours the off switch, an explicit path, and PATH")
    func discovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        #if os(macOS)
        let emptyHome = dir.appendingPathComponent("home").path
        #expect(AgyLocal.discover(environment: ["PATH": dir.path, "HOME": emptyHome])?.path == fake.path)
        #expect(AgyLocal.discover(environment: ["KWWK_AGY_PATH": fake.path, "HOME": emptyHome])?.path == fake.path)
        #expect(AgyLocal.discover(environment: ["PATH": dir.path, AgyLocal.disableEnvironmentKey: "0"]) == nil)
        #expect(AgyLocal.discover(environment: ["KWWK_AGY_PATH": dir.appendingPathComponent("missing").path]) == nil)
        #else
        #expect(AgyLocal.discover(environment: ["PATH": dir.path]) == nil)
        #endif
    }

    @Test("local models route to the agy scope on the catalog wire with no base URL")
    func localModelRouting() {
        let model = AgyLocal.model(id: "agy/claude-sonnet-5-5-high")
        #expect(model.id == "claude-sonnet-5-5-high")
        #expect(model.provider == AgyOAuth.providerId)
        #expect(model.api == AgyLocal.registryAPI)
        #expect(model.baseURL.isEmpty)
        #expect(AgyLocal.model().id == AgyModels.defaultModelId)
        #expect(providerDisplayName(forStoreId: AgyLocal.slotStoreId) == AgyLocal.displayName)
    }

    // MARK: - MCP bridge server

    @Test("the MCP bridge serves tools/list and tools/call behind its bearer secret")
    func mcpBridgeServer() async throws {
        let server = AgyMCPBridgeServer()
        try await server.start()
        defer { server.stop() }
        let token = AgyMCPBridgeServer.randomToken()
        server.setRoute(token, .init(tools: [Self.tool]) { name, arguments in
            .init(content: [AgyLocalTranscript.text("\(name):\(arguments["path"]?.stringValue ?? "")")], isError: false)
        })
        let url = try #require(server.url(for: token).flatMap(URL.init(string:)))

        func post(_ body: JSONValue, auth: Bool = true, to target: URL? = nil) async throws -> (Int, JSONValue?) {
            var request = URLRequest(url: target ?? url)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if auth { request.setValue("Bearer \(server.secret)", forHTTPHeaderField: "authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data))
        }

        let (unauthorized, _) = try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], auth: false)
        #expect(unauthorized == 401)

        let (_, initialize) = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"],
        ])
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-11-25")

        let (notified, _) = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notified == 202)

        let (_, list) = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = list?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["name"]?.stringValue == "read")
        #expect(tools.first?["inputSchema"]?["type"]?.stringValue == "object")

        let (_, call) = try await post([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "read", "arguments": ["path": "a.txt"]],
        ])
        #expect(call?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "read:a.txt")
        #expect(call?["result"]?["isError"] == .bool(false))

        server.setRoute(token, nil)
        let (_, closed) = try await post(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        #expect(closed?["error"]?["code"]?.intValue == -32001)
    }

    // MARK: - Live

    /// Two turns against the real local `agy`: the first calls a kwwk tool
    /// inline over the MCP bridge, the second must continue the same ACP
    /// session. Gated behind `KWWK_LIVE_AGY_LOCAL=1`; uses the signed-in
    /// `agy` on this machine and burns a few tokens.
    @Test("live: a tool call runs inline and the next turn reuses the session")
    func liveTwoTurns() async throws {
        guard ProcessInfo.processInfo.environment["KWWK_LIVE_AGY_LOCAL"] == "1" else {
            print("[skipped] set KWWK_LIVE_AGY_LOCAL=1 to run")
            return
        }
        let executable = try #require(AgyLocal.discover(), "no local agy found")
        let provider = AgyLocalProvider(executable: executable)
        let runtime = AgyLocalRuntime.shared(for: executable)
        let sessionId = "live-\(UUID().uuidString)"
        defer { Task { await provider.closeSession(sessionId: sessionId) } }

        let secretTool = Tool(
            name: "get_secret",
            description: "Returns the secret for a key.",
            parameters: ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]
        )
        let executed = LockedCalls()
        let bridge = CursorExecBridge(cwd: "/tmp") { call in
            executed.append(call)
            return ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: "the secret is 4217"))]
            )
        }
        let model = AgyLocal.model(id: "gemini-3.8-flash-low")
        let options = StreamOptions(sessionId: sessionId, cursorExecBridge: bridge)

        var context = Context(
            systemPrompt: "You are a terse assistant.",
            messages: [.user(UserMessage(text: "Call get_secret with key alpha, then tell me the number."))],
            tools: [secretTool]
        )
        let opened = await runtime.sessionsOpened
        let first = await provider.stream(model: model, context: context, options: options).result()
        #expect(first.stopReason == .stop, "\(first.errorMessage ?? "")")
        let calls = first.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }
        #expect(calls.first?.name == "get_secret")
        #expect(calls.allSatisfy { $0.cursorExecResolved == true })
        #expect(executed.calls.first?.arguments["key"]?.stringValue == "alpha")

        context.messages.append(.assistant(first))
        for call in executed.calls {
            context.messages.append(.toolResult(ToolResultMessage(
                toolCallId: call.id,
                toolName: call.name,
                content: [.text(TextContent(text: "the secret is 4217"))]
            )))
        }
        context.messages.append(.user(UserMessage(text: "Without tools: what number did you get?")))
        let second = await provider.stream(model: model, context: context, options: options).result()
        #expect(second.stopReason == .stop, "\(second.errorMessage ?? "")")
        let answer = second.content.compactMap { block -> String? in
            if case .text(let t) = block { return t.text }
            return nil
        }.joined()
        #expect(answer.contains("4217"))
        #expect(await runtime.sessionsOpened == opened + 1, "the second turn should continue the first session")
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolCall] = []
    func append(_ call: ToolCall) { lock.lock(); stored.append(call); lock.unlock() }
    var calls: [ToolCall] { lock.lock(); defer { lock.unlock() }; return stored }
}
