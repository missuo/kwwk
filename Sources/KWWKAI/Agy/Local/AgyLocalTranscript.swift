import Foundation
import Crypto

/// Pure planning for the local agy provider: kwwk sends the whole transcript
/// on every turn, while an ACP session keeps its own history. Decide whether
/// a turn can continue the conversation's live ACP session (sending only the
/// new input) or must open a fresh session seeded with a replay of the
/// transcript, and build the ACP prompt blocks for either.
enum AgyLocalTranscript {
    /// What a live ACP session has already seen, recorded after each turn
    /// that finished cleanly.
    struct Checkpoint: Sendable, Equatable {
        /// `context.messages.count` when the turn started.
        var consumedCount: Int
        /// Digest of `context.messages[0..<consumedCount]`.
        var consumedDigest: String
        /// `responseId` of the assistant message the turn produced; the
        /// next transcript must carry it right after the consumed prefix.
        var responseId: String
        /// Digest of the system prompt and tool list the session was opened
        /// with; ACP fixes both at `session/new`.
        var setupDigest: String
    }

    enum Plan: Equatable {
        /// Send `prompt` into the existing session.
        case continueSession(prompt: [JSONValue])
        /// Open a new session and send `prompt` (history replay + input).
        case freshSession(prompt: [JSONValue])

        var prompt: [JSONValue] {
            switch self {
            case .continueSession(let p), .freshSession(let p): return p
            }
        }
    }

    // MARK: - Planning

    static func plan(context: Context, cwd: String?, checkpoint: Checkpoint?, imagesSupported: Bool) -> Plan {
        let messages = context.messages
        if let checkpoint,
           checkpoint.setupDigest == setupDigest(context, cwd: cwd),
           let delta = continuation(messages: messages, after: checkpoint) {
            return .continueSession(prompt: inputBlocks(delta, imagesSupported: imagesSupported))
        }
        let split = splitTrailingInput(messages)
        var prompt: [JSONValue] = []
        if let replay = historyReplay(Array(messages[..<split])) {
            prompt.append(text(replay))
        }
        prompt += inputBlocks(Array(messages[split...]), imagesSupported: imagesSupported)
        return .freshSession(prompt: prompt)
    }

    /// The messages to send when `messages` extends the checkpointed
    /// transcript as expected — the consumed prefix unchanged, then the
    /// session's own reply, its inline tool results, and new input — or nil.
    static func continuation(messages: [Message], after checkpoint: Checkpoint) -> [Message]? {
        let n = checkpoint.consumedCount
        guard messages.count > n + 1,
              digest(Array(messages[..<n])) == checkpoint.consumedDigest,
              case .assistant(let reply) = messages[n],
              reply.responseId == checkpoint.responseId else { return nil }
        let resolvedIds = Set(reply.content.compactMap { block -> String? in
            if case .toolCall(let call) = block, call.cursorExecResolved == true { return call.id }
            return nil
        })
        var index = n + 1
        // The results agy already received through the MCP bridge.
        while index < messages.count,
              case .toolResult(let result) = messages[index],
              resolvedIds.contains(result.toolCallId) {
            index += 1
        }
        let rest = messages[index...].filter { $0.role != .system }
        // Anything but new user input (an assistant turn from another
        // provider, a result agy never saw) means the session diverged.
        guard !rest.isEmpty, rest.allSatisfy({ $0.role == .user }) else { return nil }
        return Array(rest)
    }

    /// Index where the trailing input begins: everything after the last
    /// assistant message.
    static func splitTrailingInput(_ messages: [Message]) -> Int {
        guard let last = messages.lastIndex(where: { $0.role == .assistant }) else { return 0 }
        return last + 1
    }

    // MARK: - Digests

    static func digest(_ messages: [Message]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        for message in messages {
            if let data = try? encoder.encode(message) { hasher.update(data: data) }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func setupDigest(_ context: Context, cwd: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: Data((context.systemPrompt ?? "").utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data((cwd ?? "").utf8))
        hasher.update(data: Data([0]))
        if let tools = context.tools, let data = try? encoder.encode(tools) {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Prompt building

    /// The kwwk system prompt plus the tool policy, appended to agy's own
    /// system prompt through `_meta.antigravity.systemPrompt.append`.
    static func systemPromptAppendix(_ context: Context, cwd: String?) -> String {
        var parts: [String] = []
        if let system = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty {
            parts.append(system)
        }
        if let tools = context.tools, !tools.isEmpty {
            let workspace = cwd.map {
                " The user's working directory is `\($0)`: resolve relative paths against it. The workspace path " +
                    "your environment reports is an empty placeholder, not the user's project."
            } ?? ""
            parts.append("""
            # Tool environment
            You are running inside kwwk, which provides your tools through the MCP server \
            `\(AgyLocal.mcpServerName)` (tool names start with `\(AgyLocal.mcpToolPrefix)`). Use only those tools. \
            Your built-in tools (run_command, read_file, write_file, list_dir, search_web, the browser and \
            similar) are disabled in this environment and every call to them is refused; use the \
            `\(AgyLocal.mcpToolPrefix)` equivalent instead.\(workspace)
            """)
        } else {
            parts.append("""
            # Tool environment
            You are running inside kwwk with no tools for this turn. Your built-in tools are disabled and \
            every call to them is refused; answer from the conversation alone.
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The transcript before the current input, as one text block, or nil
    /// when there is none.
    static func historyReplay(_ messages: [Message]) -> String? {
        var lines: [String] = []
        for message in messages {
            switch message {
            case .system:
                continue
            case .user(let user):
                let body = user.content.map { block -> String in
                    switch block {
                    case .text(let t): return t.text
                    case .image(let i): return "[\(i.mimeType) image omitted]"
                    }
                }.joined(separator: "\n")
                lines.append("[user]\n\(body)")
            case .assistant(let assistant):
                for block in assistant.content {
                    switch block {
                    case .text(let t) where !t.text.isEmpty:
                        lines.append("[assistant]\n\(t.text)")
                    case .toolCall(let call):
                        lines.append("[assistant called tool \(call.name)]\n\(compactJSON(call.arguments))")
                    default:
                        continue
                    }
                }
            case .toolResult(let result):
                lines.append("[tool result: \(result.toolName)\(result.isError ? ", error" : "")]\n\(toolResultText(result))")
            }
        }
        guard !lines.isEmpty else { return nil }
        return """
        <conversation_history>
        The conversation so far, replayed from kwwk because this session started fresh. \
        Tool calls listed here already ran; do not repeat them unless asked. Continue from the latest input below.

        \(lines.joined(separator: "\n\n"))
        </conversation_history>
        """
    }

    /// ACP content blocks for the current input. Tool results in the input
    /// (calls another provider made) are rendered as text.
    static func inputBlocks(_ messages: [Message], imagesSupported: Bool) -> [JSONValue] {
        var blocks: [JSONValue] = []
        for message in messages {
            switch message {
            case .system, .assistant:
                continue
            case .user(let user):
                for block in user.content {
                    switch block {
                    case .text(let t):
                        if !t.text.isEmpty { blocks.append(text(t.text)) }
                    case .image(let image):
                        blocks.append(imagesSupported
                            ? ["type": "image", "data": .string(image.data), "mimeType": .string(image.mimeType)]
                            : text("[\(image.mimeType) image omitted: this model does not accept images]"))
                    }
                }
            case .toolResult(let result):
                blocks.append(text("[tool result: \(result.toolName)\(result.isError ? ", error" : "")]\n\(toolResultText(result))"))
            }
        }
        return blocks.isEmpty ? [text("Continue.")] : blocks
    }

    static func toolResultText(_ result: ToolResultMessage) -> String {
        result.content.map { block -> String in
            switch block {
            case .text(let t): return t.text
            case .image(let i): return "[\(i.mimeType) image]"
            }
        }.joined(separator: "\n")
    }

    /// A kwwk tool result as MCP `tools/call` content.
    static func mcpContent(_ result: ToolResultMessage, imagesSupported: Bool) -> [JSONValue] {
        let content: [JSONValue] = result.content.map { block in
            switch block {
            case .text(let t):
                return ["type": "text", "text": .string(t.text)]
            case .image(let i):
                return imagesSupported
                    ? ["type": "image", "data": .string(i.data), "mimeType": .string(i.mimeType)]
                    : ["type": "text", "text": .string("[\(i.mimeType) image omitted]")]
            }
        }
        return content.isEmpty ? [["type": "text", "text": ""]] : content
    }

    static func text(_ s: String) -> JSONValue {
        ["type": "text", "text": .string(s)]
    }

    static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
