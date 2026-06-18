//
//  MCPConnection.swift
//  Ghostwire
//
//  GW-219: one external MCP server's live connection. Wraps the SDK Client
//  + transport and (for stdio) the spawned process. Role-neutral protocol
//  plumbing — GW-173 shares the SDK dep and health policy, not this actor.
//
//  NOTE: allowlist enforcement does NOT live here — MCPClientService is the
//  single choke point. This actor is internal plumbing.
//

import Foundation
import MCP

/// Snapshot of one tool for the UI/probe (decoupled from SDK types).
struct MCPToolInfo: Equatable, Identifiable {
    let name: String
    let description: String?
    let hasOutputSchema: Bool
    let isReadOnlyHinted: Bool?
    let isDestructiveHinted: Bool?
    var id: String { name }
}

extension MCPToolInfo {
    init(tool: Tool) {
        self.name = tool.name
        self.description = tool.description
        self.hasOutputSchema = tool.outputSchema != nil
        self.isReadOnlyHinted = tool.annotations.readOnlyHint
        self.isDestructiveHinted = tool.annotations.destructiveHint
    }
}

/// Result of a tool call with structuredContent preserved (the async SDK
/// convenience drops it — we go through RequestContext instead).
struct MCPToolCallOutput: Sendable {
    let structuredContent: Value?
    let isError: Bool?
    let textRepresentation: String
    /// Full content array (text/image/audio/resource, each with its own
    /// annotations + _meta) + the result-level _meta — kept intact so the
    /// gateway (GW-253) can forward arbitrary downstream results faithfully
    /// instead of flattening to text. `textRepresentation` stays for the
    /// text-only consumers (Settings/probe).
    let content: [Tool.Content]
    let meta: Metadata?

    init(result: CallTool.Result) {
        self.structuredContent = result.structuredContent
        self.isError = result.isError
        self.content = result.content
        self.meta = result._meta
        self.textRepresentation = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }
}

actor MCPConnection {
    enum ConnectionError: LocalizedError {
        case notConnected
        var errorDescription: String? { "Not connected to the server." }
    }

    private let serverName: String
    private var client: Client?
    private var process: StdioServerProcess?

    init(serverName: String) {
        self.serverName = serverName
    }

    /// Connect over a ready transport (http, in-memory tests).
    func connect(transport: any Transport) async throws {
        let client = Client(name: "Ghostwire", version: Self.appVersion)
        _ = try await client.connect(transport: transport)
        self.client = client
    }

    /// Connect by spawning a stdio server. Caller has already trust-gated,
    /// resolved the absolute path, and loaded env values from the Keychain.
    func connectStdio(executablePath: String, arguments: [String], environment: [String: String]) async throws {
        let process = StdioServerProcess()
        try process.start(executablePath: executablePath, arguments: arguments, environment: environment)
        self.process = process
        do {
            try await connect(transport: process.makeTransport())
        } catch {
            process.terminate()
            self.process = nil
            throw Self.annotate(error, stderrTail: process.stderrTail)
        }
    }

    func listTools() async throws -> [MCPToolInfo] {
        try await listFullTools().map(MCPToolInfo.init(tool:))
    }

    /// Full SDK `Tool`s (with `inputSchema`/`outputSchema`) — the gateway
    /// (GW-253) re-exposes these, so it needs the schemas `MCPToolInfo` drops.
    func listFullTools() async throws -> [Tool] {
        guard let client else { throw ConnectionError.notConnected }
        var collected: [Tool] = []
        var cursor: String? = nil
        repeat {
            let page = try await client.listTools(cursor: cursor)
            collected += page.tools
            cursor = page.nextCursor
        } while cursor != nil
        return collected
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        guard let client else { throw ConnectionError.notConnected }
        // RequestContext variant: the async convenience drops structuredContent.
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name, arguments: arguments)
        return MCPToolCallOutput(result: try await context.value)
    }

    func ping() async throws {
        guard let client else { throw ConnectionError.notConnected }
        try await client.ping()
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        process?.terminate()
        process = nil
    }

    var stderrTail: String { process?.stderrTail ?? "" }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private static func annotate(_ error: Error, stderrTail: String) -> Error {
        guard !stderrTail.isEmpty else { return error }
        return NSError(
            domain: "MCPConnection", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(error.localizedDescription)\n\nServer output:\n\(stderrTail)"
            ]
        )
    }
}
