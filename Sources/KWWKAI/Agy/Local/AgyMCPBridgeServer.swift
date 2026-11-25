import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// Loopback MCP server (streamable-HTTP transport, JSON responses only) that
/// exposes kwwk's tools to the local `agy acp`.
///
/// One server per process; each kwwk conversation gets its own route
/// (`/mcp/<random token>`), registered with the tool list for that
/// conversation and a call handler that runs the tool through the agent loop.
/// Requests must carry the per-process bearer secret; together with the
/// unguessable route and the 127.0.0.1 bind, nothing but the `agy` process
/// kwwk spawned can reach kwwk's tools.
final class AgyMCPBridgeServer: Sendable {
    /// Result of one MCP `tools/call`.
    struct CallResult: Sendable {
        var content: [JSONValue]
        var isError: Bool
    }

    typealias CallHandler = @Sendable (_ name: String, _ arguments: JSONValue) async -> CallResult

    struct Route: Sendable {
        var tools: [Tool]
        var onCall: CallHandler
    }

    private struct State {
        var channel: Channel?
        var port: Int?
        var routes: [String: Route] = [:]
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let state = NIOLockedValueBox(State())
    /// Sent by agy as `Authorization: Bearer <secret>` (configured through the
    /// ACP `mcpServers[].headers`).
    let secret: String

    init(secret: String = AgyMCPBridgeServer.randomToken()) {
        self.secret = secret
    }

    deinit {
        group.shutdownGracefully { _ in }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(generator.next() as UInt64, radix: 16) }.joined()
    }

    /// Bind 127.0.0.1 on a free port. Idempotent.
    func start() async throws {
        if state.withLockedValue({ $0.channel != nil }) { return }
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] child in
                let server = self
                return child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(MCPHTTPHandler(server: server))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        state.withLockedValue { state in
            state.channel = channel
            state.port = channel.localAddress?.port
        }
    }

    func stop() {
        let channel = state.withLockedValue { state -> Channel? in
            defer { state.channel = nil }
            return state.channel
        }
        _ = channel?.close()
    }

    /// The URL agy should use for `token`'s route.
    func url(for token: String) -> String? {
        guard let port = state.withLockedValue({ $0.port }) else { return nil }
        return "http://127.0.0.1:\(port)/mcp/\(token)"
    }

    func setRoute(_ token: String, _ route: Route?) {
        state.withLockedValue { $0.routes[token] = route }
    }

    func updateHandler(_ token: String, _ onCall: @escaping CallHandler) {
        state.withLockedValue { $0.routes[token]?.onCall = onCall }
    }

    fileprivate func route(_ token: String) -> Route? {
        state.withLockedValue { $0.routes[token] }
    }

    // MARK: - JSON-RPC dispatch

    /// Answer one JSON-RPC message posted to `token`'s route. Nil for a
    /// notification (HTTP 202, no body).
    fileprivate func handle(token: String, message: JSONValue) async -> JSONValue? {
        guard case .object(let object) = message, let method = object["method"]?.stringValue else {
            return Self.error(id: .null, code: -32600, message: "invalid request")
        }
        guard let id = object["id"] else { return nil }
        let params = object["params"] ?? .null
        guard let route = route(token) else {
            return Self.error(id: id, code: -32001, message: "session closed")
        }
        switch method {
        case "initialize":
            let version = params["protocolVersion"]?.stringValue ?? "2025-06-18"
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(AgyLocal.mcpServerName), "version": "1"],
            ])
        case "server/discover", "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let tools: [JSONValue] = route.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": Self.inputSchema(tool.parameters),
                ]
            }
            return Self.result(id: id, ["tools": .array(tools)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "missing tool name")
            }
            let arguments = params["arguments"] ?? .object([:])
            let outcome = await route.onCall(name, arguments)
            return Self.result(id: id, [
                "content": .array(outcome.content),
                "isError": .bool(outcome.isError),
            ])
        default:
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// MCP requires an object schema; a tool declared with none (or a
    /// non-object root) is given an empty one.
    static func inputSchema(_ parameters: JSONValue) -> JSONValue {
        guard case .object(var schema) = parameters else {
            return ["type": "object", "properties": [:]]
        }
        if schema["type"] == nil { schema["type"] = "object" }
        return .object(schema)
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

/// HTTP/1.1 front for `AgyMCPBridgeServer`: collects a POST body, checks the
/// bearer secret and route, dispatches, writes one JSON response and closes.
private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private weak var server: AgyMCPBridgeServer?
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(server: AgyMCPBridgeServer?) { self.server = server }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            self.head = nil
            let bytes = body.readBytes(length: body.readableBytes) ?? []
            body.clear()
            handle(channel: context.channel, head: head, body: Data(bytes))
        }
    }

    private func handle(channel: Channel, head: HTTPRequestHead, body: Data) {
        guard let server else {
            Self.respond(channel, .serviceUnavailable)
            return
        }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        guard path.hasPrefix("/mcp/") else {
            Self.respond(channel, .notFound)
            return
        }
        let token = String(path.dropFirst("/mcp/".count))
        guard head.headers["authorization"].first == "Bearer \(server.secret)" else {
            Self.respond(channel, .unauthorized)
            return
        }
        switch head.method {
        case .POST:
            break
        case .DELETE:
            Self.respond(channel, .ok)
            return
        default:
            // No server-initiated SSE stream: tell the client to stay on POST.
            Self.respond(channel, .methodNotAllowed)
            return
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            Self.respond(channel, .badRequest)
            return
        }
        Task {
            guard let reply = await server.handle(token: token, message: message) else {
                Self.respond(channel, .accepted)
                return
            }
            let data = (try? JSONEncoder().encode(reply)) ?? Data()
            Self.respond(channel, .ok, json: data)
        }
    }

    private static func respond(_ channel: Channel, _ status: HTTPResponseStatus, json: Data? = nil) {
        var headers = HTTPHeaders()
        if let json {
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(json.count))
        } else {
            headers.add(name: "content-length", value: "0")
        }
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            if let json {
                var buffer = channel.allocator.buffer(capacity: json.count)
                buffer.writeBytes(json)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
