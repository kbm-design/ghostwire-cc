//
//  MCPServeRuntime.swift
//  Ghostwire
//
//  GW-173: the MCP context-hub SERVER (pull side). Runs as a stdio MCP server
//  when the app binary is launched with the `mcp-serve` subcommand — the same
//  signed executable as the GUI, so `.withSecurityScope` bookmarks and file
//  entitlements resolve identically (the GUI app is not involved; this process
//  reads the persisted Shelf store directly).
//
//  Reuse boundary with GW-219: same swift-sdk `MCP` product + transport +
//  `Value`/`Tool` conventions. NOT `ConnectionHealthPolicy` — that supervises
//  an OUTBOUND client connection; here the agent supervises us, so it does not
//  apply to the serve direction.
//
//  stdio protocol safety: JSON-RPC owns fd 1 (stdout). Stray `print(...)` in
//  app code (e.g. ShelfPersistenceService) would corrupt the stream, so we dup
//  the real stdout for the transport and redirect fd 1 -> stderr first thing.
//

import Defaults
import Foundation
import MCP
import System

enum MCPServeRuntime {
    static let serverName = "ghostwire"
    static let recentResourceURI = "notch://saves/recent"

    /// Entry point for the `mcp-serve` subcommand. Never returns — serves until
    /// the client closes stdin, then exits.
    static func main() -> Never {
        // Protect the protocol channel: hand the transport the *real* stdout,
        // then point fd 1 at stderr so any stray writes are harmless.
        let realStdout = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        let transport = StdioTransport(
            input: .standardInput,
            output: FileDescriptor(rawValue: realStdout)
        )

        Task {
            await serve(transport: transport)
            exit(EXIT_SUCCESS)
        }
        dispatchMain()
    }

    /// Wire up and run the server over a ready transport. Factored out so tests
    /// can drive it over an in-memory transport.
    static func serve(transport: any Transport) async {
        let server = await makeServer()
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(
                Data("ghostwire mcp-serve: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Factory for the read-only Shelf view. Injectable so tests can flow data
    /// through the SDK without touching the user's real Shelf file. Nonisolated:
    /// the serve subprocess has no main run loop to drain @MainActor work.
    typealias ProviderFactory = @Sendable () -> ShelfContextProvider

    /// Build the server with the three pull-side tools and the optional
    /// recent-saves resource. Pure (no transport) so tests can introspect it.
    static func makeServer(
        provider: @escaping ProviderFactory = { ShelfContextProvider() }
    ) async -> Server {
        let server = Server(
            name: serverName,
            version: appVersion,
            instructions: """
                Ghostwire's Shelf is the user's local hold-store of files, text \
                snippets, and links they saved for later. Use `get_held_items` to \
                see what's there, `search_saves` to find something by keyword, and \
                `get_file` to pull a specific item's path and/or contents. \
                Everything is local and read-only; nothing is written back.
                """,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Tools.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await handleCall(name: params.name, arguments: params.arguments, provider: provider)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "Recent Shelf saves",
                    uri: recentResourceURI,
                    description: "A markdown digest of the most recent items held in Ghostwire's Shelf.",
                    mimeType: "text/markdown"
                )
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == recentResourceURI else {
                throw MCPError.invalidParams("Unknown resource: \(params.uri)")
            }
            let markdown = await recentSavesMarkdown(provider: provider)
            return ReadResource.Result(contents: [
                .text(markdown, uri: recentResourceURI, mimeType: "text/markdown")
            ])
        }

        return server
    }

    // MARK: - Tool dispatch

    private static func handleCall(
        name: String, arguments: [String: Value]?, provider: @escaping ProviderFactory
    ) async -> CallTool.Result {
        guard Defaults[.mcpServeEnabled] else {
            return gatedResult()
        }
        switch name {
        case Tools.getHeldItems.name:
            let includeTemporary = arguments?["include_temporary"]?.boolValue ?? false
            let items = provider().heldItems(includeTemporary: includeTemporary)
            return listResult(items)

        case Tools.searchSaves.name:
            guard let query = arguments?["query"]?.stringValue else {
                return errorResult("`query` (string) is required.")
            }
            let includeTemporary = arguments?["include_temporary"]?.boolValue ?? false
            let items = provider().search(query, includeTemporary: includeTemporary)
            return listResult(items)

        case Tools.getFile.name:
            guard let id = arguments?["id"]?.stringValue else {
                return errorResult("`id` (string) is required.")
            }
            let resolved = provider().resolve(id: id)
            guard let resolved else {
                return errorResult("No held item with id \(id).")
            }
            return resolvedResult(resolved)

        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: - Result builders

    private static func listResult(_ items: [HeldItemSnapshot]) -> CallTool.Result {
        let summary = items.isEmpty
            ? "The Shelf is empty."
            : items.map { "• [\($0.kind.rawValue)] \($0.displayName) (id: \($0.id))" }
                .joined(separator: "\n")
        return (try? CallTool.Result(
            content: [.text(text: summary, annotations: nil, _meta: nil)],
            structuredContent: ListOutput(count: items.count, items: items),
            isError: false
        )) ?? CallTool.Result(content: [.text(text: summary, annotations: nil, _meta: nil)])
    }

    private static func resolvedResult(_ item: ResolvedShelfItem) -> CallTool.Result {
        let text = item.content ?? item.path ?? item.note ?? item.displayName
        return (try? CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: item,
            isError: false
        )) ?? CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func gatedResult() -> CallTool.Result {
        CallTool.Result(
            content: [.text(
                text: "Shelf access for agents is turned off. Enable it in Ghostwire → Agents → Shelf access.",
                annotations: nil, _meta: nil)],
            isError: false)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true)
    }

    private static func recentSavesMarkdown(provider: @escaping ProviderFactory) async -> String {
        guard Defaults[.mcpServeEnabled] else {
            return "_Shelf access for agents is turned off._"
        }
        let items = provider().heldItems()
        guard !items.isEmpty else { return "_The Shelf is empty._" }
        let lines = items.prefix(50).map { snap -> String in
            switch snap.kind {
            case .file: return "- 📄 **\(snap.displayName)** — `\(snap.path ?? "unavailable")`"
            case .text: return "- 📝 \(snap.displayName)"
            case .link: return "- 🔗 \(snap.displayName)"
            }
        }
        return "# Recent Shelf saves\n\n" + lines.joined(separator: "\n")
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    /// Structured payload for the list/search tools.
    private struct ListOutput: Codable, Sendable {
        let count: Int
        let items: [HeldItemSnapshot]
    }
}

// MARK: - Tool definitions

extension MCPServeRuntime {
    enum Tools {
        static let all: [Tool] = [getHeldItems, searchSaves, getFile]

        static let getHeldItems = Tool(
            name: "get_held_items",
            description: "List the items currently held in the user's Ghostwire Shelf "
                + "(files, text snippets, links), newest first. Returns id, kind, "
                + "display name, and — for files — path, size, and modified time.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "include_temporary": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Include transient/auto-captured items. Defaults to false."),
                    ])
                ]),
            ]),
            annotations: readOnly
        )

        static let searchSaves = Tool(
            name: "search_saves",
            description: "Search the user's Ghostwire Shelf by keyword over item names, "
                + "file paths, text, and link URLs. Returns matching items newest first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring to match."),
                    ]),
                    "include_temporary": .object([
                        "type": .string("boolean"),
                        "description": .string("Include transient items. Defaults to false."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
            annotations: readOnly
        )

        static let getFile = Tool(
            name: "get_file",
            description: "Resolve one held item by id. Returns a filesystem `path` for "
                + "capable agents and, for textual files within the size cap, inline "
                + "`content` for sandboxed consumers. Text and link items return their "
                + "value inline.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The item id from get_held_items / search_saves."),
                    ])
                ]),
                "required": .array([.string("id")]),
            ]),
            annotations: readOnly
        )

        /// All pull-side tools are read-only and closed-world (the Shelf only).
        private static let readOnly = Tool.Annotations(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    }
}
