//
//  MCPServerConfigStore.swift
//  Ghostwire
//
//  GW-219: source-of-truth persistence for NCC's own MCP server list.
//  Plain JSON at ~/.ghostwire/mcp-servers.json — auditable by the user,
//  and guaranteed secret-free (see MCPServerConfig).
//

import Foundation

final class MCPServerConfigStore {
    private(set) var servers: [MCPServerConfig] = []
    private let fileURL: URL

    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("mcp-servers.json")

    init(fileURL: URL = MCPServerConfigStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func add(_ config: MCPServerConfig) {
        servers.append(config)
        persist()
    }

    func update(_ config: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        persist()
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        persist()
    }

    func server(id: UUID) -> MCPServerConfig? {
        servers.first { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? Self.decoder.decode([MCPServerConfig].self, from: data)
        else { return }
        servers = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(servers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MCPServerConfigStore: persist failed: \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
