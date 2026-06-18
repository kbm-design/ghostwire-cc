//
//  GatewayHTTPListener.swift
//  Ghostwire
//
//  GW-253 Phase 2: the localhost HTTP listener that fronts the MCP gateway.
//
//  Vendored + trimmed from the swift-sdk's own conformance example
//  (`Sources/MCPConformance/Server/HTTPApp.swift`, Apache-2.0) — the
//  maintainer-authored reference listener. The SDK ships the framework-agnostic
//  `StatefulHTTPServerTransport` (request -> response, incl. SSE) but no actual
//  HTTP server; this is the NIO bridge that opens the socket and pipes NIO
//  HTTP <-> the SDK's `HTTPRequest`/`HTTPResponse`.
//
//  Adaptations from the SDK example:
//   - os.Logger instead of swift-log (the app has no swift-log dependency).
//   - local `isInitializeRequest` JSON check (the SDK's `JSONRPCMessageKind` is
//     `package`-internal, not visible to this module).
//   - bind 127.0.0.1 only; the transport's default validation pipeline already
//     enforces localhost `Origin`. Bearer-token auth is layered in separately.
//
//  Original copyright: Copyright (c) 2025 the Swift MCP SDK authors. Apache-2.0.
//

import Foundation
import MCP
import os
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

actor GatewayHTTPListener {
    struct Configuration: Sendable {
        var host: String
        var port: Int
        var endpoint: String
        var sessionTimeout: TimeInterval

        init(
            host: String = "127.0.0.1",
            port: Int = 51762,
            endpoint: String = "/mcp",
            sessionTimeout: TimeInterval = 3600
        ) {
            self.host = host
            self.port = port
            self.endpoint = endpoint
            self.sessionTimeout = sessionTimeout
        }
    }

    /// Builds an MCP `Server` per session. The closure injects the gateway over
    /// the app's live connections (runs in-process, so it can reach them).
    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async throws -> Server

    /// Optional per-request gate (bearer token). Returns nil to allow, or an
    /// `HTTPResponse` to reject. Runs before session routing.
    typealias RequestGate = @Sendable (HTTPRequest) -> HTTPResponse?

    private let configuration: Configuration
    private let serverFactory: ServerFactory
    private let gate: RequestGate?
    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [String: SessionContext] = [:]

    static let log = Logger(subsystem: "com.ghostwire.notch", category: "mcp-gateway-http")

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(
        configuration: Configuration = Configuration(),
        gate: RequestGate? = nil,
        serverFactory: @escaping ServerFactory
    ) {
        self.configuration = configuration
        self.serverFactory = serverFactory
        self.gate = gate
    }

    var endpoint: String { configuration.endpoint }

    // MARK: - Lifecycle

    /// Binds and serves. Returns once bound; serving continues on the event loop.
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(listener: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.channel = channel
        Self.log.info("MCP gateway HTTP listening on \(self.configuration.host, privacy: .public):\(self.configuration.port, privacy: .public)\(self.configuration.endpoint, privacy: .public)")

        Task { await sessionCleanupLoop() }
    }

    func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
        Self.log.info("MCP gateway HTTP stopped")
    }

    // MARK: - Request routing

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if let gate, let rejection = gate(request) {
            return rejection
        }

        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return response
        }

        if request.method.uppercased() == "POST", let body = request.body, Self.isInitializeRequest(body) {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    // MARK: - Sessions

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        // validationPipeline: nil -> the transport applies its secure defaults
        // (OriginValidator.localhost(), Accept/ContentType/ProtocolVersion/Session).
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID))
        do {
            let server = try await serverFactory(sessionID, transport)
            try await server.start(transport: transport)
            sessions[sessionID] = SessionContext(
                server: server, transport: transport, createdAt: Date(), lastAccessedAt: Date())
            let response = await transport.handleRequest(request)
            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }
            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)"))
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys { await closeSession(sessionID) }
    }

    private func sessionCleanupLoop() async {
        while channel != nil {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter {
                now.timeIntervalSince($0.value.lastAccessedAt) > configuration.sessionTimeout
            }
            for (sessionID, _) in expired { await closeSession(sessionID) }
        }
    }

    /// Minimal stand-in for the SDK's `package`-internal initialize detection.
    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return object["method"] as? String == "initialize"
    }
}

// MARK: - NIO HTTP handler (NIO <-> HTTPRequest/HTTPResponse bridge)

private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let listener: GatewayHTTPListener

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }
    private var requestState: RequestState?

    init(listener: GatewayHTTPListener) { self.listener = listener }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head, bodyBuffer: context.channel.allocator.buffer(capacity: 0))
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil
            nonisolated(unsafe) let ctx = context
            Task { await self.handleRequest(state: state, context: ctx) }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await listener.endpoint
        guard path == endpoint else {
            await writeResponse(.error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version, context: context)
            return
        }
        let httpRequest = makeHTTPRequest(from: state)
        let response = await listener.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes) {
            body = Data(bytes)
        } else {
            body = nil
        }
        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))
        return HTTPRequest(
            method: state.head.method.rawValue, headers: headers, body: body, path: path)
    }

    private func writeResponse(
        _ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop
        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {}
            eventLoop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version, status: HTTPResponseStatus(statusCode: statusCode))
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
