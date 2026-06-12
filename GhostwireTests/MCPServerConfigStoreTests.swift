import XCTest

@testable import Ghostwire

final class MCPServerConfigStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-servers-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeStdioConfig() -> MCPServerConfig {
        MCPServerConfig(
            id: UUID(),
            name: "Test Server",
            transport: .stdio(command: "npx", arguments: ["-y", "@example/server"], environmentKeys: ["API_KEY"]),
            resolvedExecutablePath: "/opt/homebrew/bin/npx"
        )
    }

    func testRoundTripPersistsServers() {
        let store = MCPServerConfigStore(fileURL: tempURL)
        let config = makeStdioConfig()
        store.add(config)

        let reloaded = MCPServerConfigStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.servers, [config])
    }

    func testAllowlistDefaultsToEmpty_defaultDeny() {
        XCTAssertTrue(makeStdioConfig().allowedTools.isEmpty)
    }

    func testNewStdioConfigIsUntrusted() {
        XCTAssertNil(makeStdioConfig().trustedCommandSignature)
    }

    func testUpdateRewritesExistingServer() {
        let store = MCPServerConfigStore(fileURL: tempURL)
        var config = makeStdioConfig()
        store.add(config)
        config.allowedTools = ["get_price"]
        store.update(config)
        XCTAssertEqual(store.servers.first?.allowedTools, ["get_price"])
    }

    func testRemoveDeletesServer() {
        let store = MCPServerConfigStore(fileURL: tempURL)
        let config = makeStdioConfig()
        store.add(config)
        store.remove(id: config.id)
        XCTAssertTrue(store.servers.isEmpty)
    }

    /// Security invariant 3: the persisted JSON may contain env KEY NAMES but
    /// must never contain anything that looks like a value slot for them.
    func testPersistedJSONContainsKeyNamesOnly() throws {
        let store = MCPServerConfigStore(fileURL: tempURL)
        store.add(makeStdioConfig())
        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("API_KEY"))  // key name is fine
        XCTAssertFalse(raw.lowercased().contains("secret"))
        XCTAssertFalse(raw.contains("environmentValues"))  // no value field exists at all
    }

    func testTrustSignatureMatchesCurrentCommandLine() {
        var config = makeStdioConfig()
        config.trustedCommandSignature = config.commandSignature
        XCTAssertTrue(config.isTrusted)
        // editing args invalidates trust
        config.transport = .stdio(command: "npx", arguments: ["-y", "@evil/server"], environmentKeys: [])
        XCTAssertFalse(config.isTrusted)
    }

    func testHTTPConfigIsAlwaysTrusted_noSpawn() {
        let config = MCPServerConfig(
            id: UUID(), name: "Hosted",
            transport: .http(endpoint: URL(string: "https://mcp.example.com/mcp")!)
        )
        XCTAssertTrue(config.isTrusted)
    }
}
