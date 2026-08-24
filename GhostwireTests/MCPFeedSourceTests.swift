//
//  MCPFeedSourceTests.swift
//  GhostwireTests
//
//  GW-214. Two things break in an MCP-backed Source: the SHAPE guess (a tool
//  result is arbitrary JSON, and the mapper has to pick a card kind from it) and
//  the STATE machine (which server postures become a "Needs attention" card
//  versus a thrown refresh). Both are covered here without a live server — the
//  mapper is pure, and the state machine runs against a fake backend.
//

import Combine
import MCP
import XCTest

@testable import Ghostwire

// MARK: - Fake backend

@MainActor
private final class FakeMCPFeedBackend: MCPFeedBackend {
    var status: MCPServerRuntime.Status = .connected(toolCount: 1)
    /// Status to adopt once `connect` is called — models the lazy reconnect.
    var statusAfterConnect: MCPServerRuntime.Status?
    var connectCount = 0
    var calls: [(tool: String, arguments: [String: Value]?)] = []
    var results: [String: Result<MCPToolCallOutput, Error>] = [:]

    /// Tool schemas the source can consult; empty means "not connected yet".
    var toolInfo: [String: MCPToolInfo] = [:]

    func feedRuntimeStatus(serverID: UUID) -> MCPServerRuntime.Status { status }

    func feedToolInfo(serverID: UUID, tool: String) -> MCPToolInfo? { toolInfo[tool] }

    func connect(id: UUID) async {
        connectCount += 1
        if let statusAfterConnect { status = statusAfterConnect }
    }

    func callAllowedTool(serverID: UUID, name: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput {
        calls.append((name, arguments))
        switch results[name] {
        case .success(let output): return output
        case .failure(let error): throw error
        case nil: return makeOutput(structured: nil, text: "")
        }
    }
}

/// `MCPToolCallOutput` only has an `init(from: CallTool.Result)`, so fixtures are
/// built the same way a real call would be.
private func makeOutput(
    structured: Value?, text: String, isError: Bool? = nil
) -> MCPToolCallOutput {
    MCPToolCallOutput(
        result: CallTool.Result(
            content: text.isEmpty ? [] : [.text(text)],
            structuredContent: structured,
            isError: isError
        )
    )
}

// MARK: - Mapping: result shape → card kind

final class MCPFeedCardMapperTests: XCTestCase {
    private func kind(_ structured: Value?, text: String = "", isError: Bool? = nil)
        -> FeedCardKind {
        MCPFeedCardMapper.kind(
            from: makeOutput(structured: structured, text: text, isError: isError),
            tool: "list_issues",
            serverName: "Linear"
        )
    }

    // MARK: Headings

    func testHeadingNamesTheServerAndTheTool() {
        XCTAssertEqual(
            MCPFeedCardMapper.title(tool: "list_issues", serverName: "Linear"),
            "Linear · List Issues")
    }

    func testCamelCaseToolNamesBecomeWords() {
        // MCPToolFormatter.toTitleCase would render this "Getuserinfo".
        XCTAssertEqual(MCPFeedCardMapper.readableToolName("getUserInfo"), "Get User Info")
        XCTAssertEqual(MCPFeedCardMapper.readableToolName("list_issues"), "List Issues")
        XCTAssertEqual(MCPFeedCardMapper.readableToolName("get-repo-status"), "Get Repo Status")
    }

    // MARK: Lists — the Linear→.list mapping GW-214 calls the obvious first one

    func testWrappedArrayOfObjectsBecomesAListOfTitles() {
        let payload = Value.object([
            "issues": .array([
                .object(["identifier": .string("GW-214"), "title": .string("MCP feed sources")]),
                .object(["identifier": .string("GW-328"), "title": .string("7-kind taxonomy")]),
            ])
        ])
        guard case let .list(title, items) = kind(payload) else {
            return XCTFail("expected .list, got \(kind(payload))")
        }
        XCTAssertEqual(title, "Linear · List Issues")
        // The identifier prefixes the title — either half alone reads worse.
        XCTAssertEqual(items, ["GW-214 MCP feed sources", "GW-328 7-kind taxonomy"])
    }

    func testBareArrayOfStringsBecomesAList() {
        guard case let .list(_, items) = kind(.array([.string("one"), .string("two")])) else {
            return XCTFail("expected .list")
        }
        XCTAssertEqual(items, ["one", "two"])
    }

    /// The handle prefix is cross-tracker, not Linear-specific: these are the
    /// four spellings trackers converged on.
    func testShortHandleFromAnyTrackerPrefixesTheRow() {
        let cases: [(String, Value, String)] = [
            ("identifier", .string("GW-332"), "GW-332 Ship it"),   // Linear
            ("id", .string("GW-332"), "GW-332 Ship it"),           // Linear (list_issues)
            ("key", .string("PROJ-12"), "PROJ-12 Ship it"),        // Jira
            ("number", .int(332), "332 Ship it"),                  // GitHub
            ("shortId", .string("ABC-1"), "ABC-1 Ship it"),        // Sentry
        ]
        for (key, value, expected) in cases {
            let row = MCPFeedCardMapper.row(
                for: .object([key: value, "title": .string("Ship it")]))
            XCTAssertEqual(row, expected, "handle key \(key)")
        }
    }

    /// The length cap is what does the filtering — a UUID or database id is
    /// never a useful prefix, and this is why the rule needs no vendor list.
    func testLongIdIsNotTreatedAsAHandle() {
        let row = MCPFeedCardMapper.row(
            for: .object([
                "id": .string("3F2504E0-4F89-11D3-9A0C-0305E82C3301"),
                "title": .string("Ship it"),
            ]))
        XCTAssertEqual(row, "Ship it")
    }

    func testHandleAloneIsNotPrefixedWithItself() {
        XCTAssertEqual(MCPFeedCardMapper.row(for: .object(["id": .string("GW-332")])), "GW-332")
    }

    func testRowFallsBackThroughTheFieldPreferenceOrder() {
        XCTAssertEqual(MCPFeedCardMapper.row(for: .object(["name": .string("Deploy")])), "Deploy")
        XCTAssertEqual(
            MCPFeedCardMapper.row(for: .object(["summary": .string("Ships tomorrow")])),
            "Ships tomorrow")
        // No known field at all: the first scalar by key still beats nothing.
        XCTAssertEqual(MCPFeedCardMapper.row(for: .object(["zzz": .string("last resort")])),
                       "last resort")
        // Nothing renderable — the row is dropped rather than shown as an object.
        XCTAssertNil(MCPFeedCardMapper.row(for: .object(["nested": .object([:])])))
    }

    func testListIsCappedButTheCountStaysHonest() {
        let many = (1...30).map { Value.string("item \($0)") }
        guard case let .list(_, items) = kind(.array(many)) else { return XCTFail("expected .list") }
        XCTAssertEqual(items.count, MCPFeedCardMapper.maxListItems)
    }

    /// GW-285: "no issues assigned to you" is a success whose value is zero. It
    /// belongs inside Has data, never in the attention state.
    func testEmptyCollectionRendersAsZeroNotAsAFailure() {
        guard case let .data(label, value, _) = kind(.object(["issues": .array([])])) else {
            return XCTFail("expected .data, got \(kind(.object(["issues": .array([])])))")
        }
        XCTAssertEqual(label, "Linear · List Issues")
        XCTAssertEqual(value, "0")
    }

    func testTwoCollectionsAreAmbiguousSoTheScalarTotalWins() {
        let payload = Value.object([
            "issues": .array([.string("a")]),
            "projects": .array([.string("b")]),
            "total": .int(2),
        ])
        guard case let .data(_, value, _) = kind(payload) else {
            return XCTFail("expected .data, got \(kind(payload))")
        }
        XCTAssertEqual(value, "2")
    }

    // MARK: Numbers

    func testSingleScalarObjectBecomesAMetric() {
        guard case let .data(label, value, delta) = kind(.object(["count": .int(1234)])) else {
            return XCTFail("expected .data")
        }
        XCTAssertEqual(label, "Linear · List Issues")
        // Counts are grouped but never given decimals.
        XCTAssertEqual(value, "1,234")
        XCTAssertNil(delta)
    }

    func testLabelValueShapeBecomesAKeyValueCard() {
        let payload = Value.object([
            "label": .string("Open PRs"), "value": .int(7), "delta": .string("+2"),
        ])
        guard case let .data(label, value, delta) = kind(payload) else {
            return XCTFail("expected .data")
        }
        XCTAssertEqual(label, "Open PRs")
        XCTAssertEqual(value, "7")
        XCTAssertEqual(delta, "+2")
    }

    func testFlatObjectBecomesKeyValueRows() {
        guard case let .list(_, items) = kind(.object(["open": .int(12), "closed": .int(3)])) else {
            return XCTFail("expected .list")
        }
        XCTAssertEqual(items, ["closed: 3", "open: 12"])
    }

    // MARK: Text and fallbacks

    func testTextOnlyResultBecomesAProseCard() {
        guard case let .text(title, body) = kind(nil, text: "All systems operational") else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(title, "Linear · List Issues")
        XCTAssertEqual(body, "All systems operational")
    }

    /// The `outputSchema`-adoption gap GW-214 names as its gating risk: plenty of
    /// servers put the structured payload in a text block instead.
    func testJSONInATextBlockIsStillMappedByShape() {
        let json = #"{"issues":[{"title":"Ship it"}]}"#
        guard case let .list(_, items) = kind(nil, text: json) else {
            return XCTFail("expected .list, got \(kind(nil, text: json))")
        }
        XCTAssertEqual(items, ["Ship it"])
    }

    func testServerReportedErrorBecomesAnAttentionCard() {
        guard case let .generic(title, subtitle, value) = kind(
            nil, text: "Rate limited\nretry in 60s", isError: true)
        else { return XCTFail("expected .generic") }
        XCTAssertEqual(title, "Linear · List Issues")
        // One line of copy — the rest is detail the card has no room for.
        XCTAssertEqual(subtitle, "Rate limited")
        XCTAssertNil(value)
    }

    func testNothingAtAllStillRendersRatherThanVanishing() {
        guard case let .generic(_, subtitle, _) = kind(nil, text: "") else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(subtitle, "No data")
    }

    func testUnrenderableStructuredContentFallsBackToTheText() {
        // An object of nested objects has no scalar and no sole array.
        let payload = Value.object(["a": .object([:]), "b": .object([:])])
        guard case let .text(_, body) = kind(payload, text: "raw fallback") else {
            return XCTFail("expected .text, got \(kind(payload, text: "raw fallback"))")
        }
        XCTAssertEqual(body, "raw fallback")
    }
}

// MARK: - State machine: server posture → cards

@MainActor
final class MCPFeedSourceStateTests: XCTestCase {
    private let serverID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private func source(
        _ backend: FakeMCPFeedBackend, bindings: [MCPFeedToolBinding] = [.init(tool: "list_issues")]
    ) -> MCPFeedSource {
        MCPFeedSource(
            serverID: serverID, serverName: "Linear", bindings: bindings, backend: backend)
    }

    func testSourceIdIsKeyedToTheServerUUIDSoRenamesDontOrphanCardOrder() {
        let backend = FakeMCPFeedBackend()
        let renamed = MCPFeedSource(
            serverID: serverID, serverName: "Linear (work)", bindings: [], backend: backend)
        XCTAssertEqual(source(backend).id, renamed.id)
        XCTAssertEqual(renamed.id, "mcp.\(serverID.uuidString)")
    }

    func testConnectedServerProducesOneCardPerBinding() async throws {
        let backend = FakeMCPFeedBackend()
        backend.results["list_issues"] = .success(
            makeOutput(structured: .object(["count": .int(3)]), text: ""))
        backend.results["list_projects"] = .success(
            makeOutput(structured: .object(["count": .int(1)]), text: ""))

        let cards = try await source(
            backend,
            bindings: [.init(tool: "list_issues"), .init(tool: "list_projects")]
        ).fetch()

        XCTAssertEqual(
            cards.map(\.id),
            ["mcp.\(serverID.uuidString).list_issues", "mcp.\(serverID.uuidString).list_projects"])
        XCTAssertEqual(backend.connectCount, 0)  // already connected
    }

    /// Nothing connects MCP servers at launch, so a Source that didn't do this
    /// would show "Connect" forever until the user opened Settings.
    func testDisconnectedServerIsConnectedLazilyThenFetched() async throws {
        let backend = FakeMCPFeedBackend()
        backend.status = .disconnected
        backend.statusAfterConnect = .connected(toolCount: 1)
        backend.results["list_issues"] = .success(
            makeOutput(structured: .object(["count": .int(3)]), text: ""))

        let cards = try await source(backend).fetch()

        XCTAssertEqual(backend.connectCount, 1)
        XCTAssertEqual(cards.count, 1)
        guard case .data = cards[0].kind else { return XCTFail("expected data, not attention") }
    }

    func testUnreachableServerCollapsesToASingleAttentionCard() async throws {
        let backend = FakeMCPFeedBackend()
        backend.status = .disconnected
        backend.statusAfterConnect = .needsAuth

        let cards = try await source(
            backend, bindings: [.init(tool: "a"), .init(tool: "b")]
        ).fetch()

        // Two bindings, one card: every tool is unavailable for the same reason,
        // so N copies of the same sentence would be noise.
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].id, "mcp.\(serverID.uuidString)#server")
        guard case let .generic(title, subtitle, _) = cards[0].kind else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(title, "Linear")
        XCTAssertEqual(subtitle, "Sign in to this server in Connections.")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testEveryUnavailablePostureGetsItsOwnWordsButTheSameShape() {
        // GW-285: needsAuth / needsTrust / failed / disconnected are ONE state.
        XCTAssertEqual(
            MCPFeedSource.attentionCopy(for: .failed(reason: "connection refused")),
            "connection refused")
        XCTAssertTrue(MCPFeedSource.attentionCopy(for: .needsTrust).contains("Trust"))
        XCTAssertTrue(MCPFeedSource.attentionCopy(for: .disconnected).contains("Not connected"))
    }

    /// A connect driven by the Settings sheet is in flight — throwing lets the
    /// coordinator keep the previous cards instead of flashing attention and back.
    func testConnectInFlightThrowsRatherThanRacingIt() async {
        let backend = FakeMCPFeedBackend()
        backend.status = .connecting
        do {
            _ = try await source(backend).fetch()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? MCPFeedSourceError, .connectInFlight)
            XCTAssertEqual(backend.connectCount, 0)
        }
    }

    /// One failing tool must not blank the ones that work, and its card keeps the
    /// SAME id so it swaps in place instead of churning the user's order.
    func testOneFailingToolBecomesAnAttentionCardWithoutTakingTheOthersDown() async throws {
        let backend = FakeMCPFeedBackend()
        backend.results["ok"] = .success(makeOutput(structured: .int(42), text: ""))
        backend.results["broken"] = .failure(
            MCPClientService.ServiceError.toolNotAllowed("broken"))

        let cards = try await source(
            backend, bindings: [.init(tool: "ok"), .init(tool: "broken")]
        ).fetch()

        XCTAssertEqual(cards.count, 2)
        guard case .data = cards[0].kind else { return XCTFail("expected the good card to survive") }
        XCTAssertEqual(cards[1].id, "mcp.\(serverID.uuidString).broken")
        guard case let .generic(_, subtitle, _) = cards[1].kind else {
            return XCTFail("expected .generic")
        }
        XCTAssertEqual(subtitle, MCPClientService.ServiceError.toolNotAllowed("broken").errorDescription)
    }

    func testBindingArgumentsReachTheCallAndBadJSONDegradesToEmpty() async throws {
        let backend = FakeMCPFeedBackend()
        _ = try await source(
            backend, bindings: [.init(tool: "t", argumentsJSON: #"{"limit": 5}"#)]
        ).fetch()
        XCTAssertEqual(backend.calls.first?.arguments, ["limit": .int(5)])

        let second = FakeMCPFeedBackend()
        // A half-typed argument must not kill the refresh loop.
        _ = try await source(second, bindings: [.init(tool: "t", argumentsJSON: "{limit")]).fetch()
        XCTAssertEqual(second.calls.first?.arguments, [:])
    }

    /// Codex P2: the pre-filled template must not start polling with blanks —
    /// that's an empty search on a timer against a billing-backed API.
    func testUnfilledPlaceholderIsNeverCalled() async throws {
        let backend = FakeMCPFeedBackend()
        let cards = try await source(
            backend,
            bindings: [.init(tool: "web_search_exa", argumentsJSON: #"{"query": ""}"#)]
        ).fetch()

        XCTAssertTrue(backend.calls.isEmpty, "must not call a tool with blank required args")
        guard case let .generic(_, subtitle, _) = cards[0].kind else {
            return XCTFail("expected an attention card")
        }
        XCTAssertEqual(subtitle, "Needs query — remove this card in Cards.")
    }

    func testFilledArgumentsBecomeRunnable() async throws {
        let backend = FakeMCPFeedBackend()
        backend.results["web_search_exa"] = .success(makeOutput(structured: .int(1), text: ""))
        _ = try await source(
            backend,
            bindings: [.init(tool: "web_search_exa", argumentsJSON: #"{"query": "notch"}"#)]
        ).fetch()
        XCTAssertEqual(backend.calls.first?.arguments, ["query": .string("notch")])
    }

    /// Live-drive find: clearing the arguments field leaves NO key at all, so
    /// the blank-value check can't see it. It reached the server and came back
    /// as "MCP error -32602: Invalid arguments for tool web_search_exa".
    func testClearedArgumentsAreCaughtViaTheToolSchema() async throws {
        let backend = FakeMCPFeedBackend()
        backend.toolInfo["web_search_exa"] = MCPToolInfo(
            name: "web_search_exa", description: nil, hasOutputSchema: false,
            isReadOnlyHinted: true, isDestructiveHinted: false, requiredInputs: ["query"])

        let cards = try await source(
            backend, bindings: [.init(tool: "web_search_exa", argumentsJSON: "{}")]
        ).fetch()

        XCTAssertTrue(backend.calls.isEmpty, "must not call with a required key absent")
        guard case let .generic(_, subtitle, _) = cards[0].kind else {
            return XCTFail("expected an attention card")
        }
        XCTAssertEqual(subtitle, "Needs query — remove this card in Cards.")
    }

    func testMissingArgumentsCoversBothAbsentKeysAndBlankValues() {
        // Absent key.
        XCTAssertEqual(
            MCPFeedToolBinding(tool: "t", argumentsJSON: "{}")
                .missingArguments(requiredInputs: ["query"]), ["query"])
        // Blank placeholder — caught even with no schema available.
        XCTAssertEqual(
            MCPFeedToolBinding(tool: "t", argumentsJSON: #"{"query": ""}"#)
                .missingArguments(requiredInputs: []), ["query"])
        // Satisfied.
        XCTAssertTrue(
            MCPFeedToolBinding(tool: "t", argumentsJSON: #"{"query": "notch"}"#)
                .missingArguments(requiredInputs: ["query"]).isEmpty)
        // A tool requiring nothing, with no arguments, is fine.
        XCTAssertTrue(
            MCPFeedToolBinding(tool: "t").missingArguments(requiredInputs: []).isEmpty)
    }

    func testBlankArgumentKeysIdentifyUnfilledPlaceholders() {
        XCTAssertTrue(MCPFeedToolBinding(tool: "t").blankArgumentKeys.isEmpty)
        XCTAssertTrue(
            MCPFeedToolBinding(tool: "t", argumentsJSON: #"{"limit": 5}"#)
                .blankArgumentKeys.isEmpty)
        XCTAssertEqual(
            MCPFeedToolBinding(tool: "t", argumentsJSON: #"{"a": "", "b": "x"}"#)
                .blankArgumentKeys, ["a"])
    }

    func testArgumentValidationFlagsTheTypoWhileItIsStillFixable() {
        XCTAssertTrue(MCPFeedToolBinding(tool: "t").hasValidArguments)
        XCTAssertTrue(MCPFeedToolBinding(tool: "t", argumentsJSON: "  ").hasValidArguments)
        XCTAssertFalse(MCPFeedToolBinding(tool: "t", argumentsJSON: "{limit").hasValidArguments)
        // A JSON array is valid JSON but not a valid arguments object.
        XCTAssertFalse(MCPFeedToolBinding(tool: "t", argumentsJSON: "[1,2]").hasValidArguments)
    }
}

// MARK: - Feed candidacy: a standing value vs a question

/// The curation rule that keeps search tools off a poll loop. A tool requiring
/// input is a *query* — putting `web_search_exa` on a 5-minute timer re-asks one
/// frozen question forever and bills for every repeat.
final class MCPToolFeedCandidacyTests: XCTestCase {
    private func info(
        required: [String] = [], readOnly: Bool? = true, destructive: Bool? = false
    ) -> MCPToolInfo {
        MCPToolInfo(
            name: "t", description: nil, hasOutputSchema: false, isReadOnlyHinted: readOnly,
            isDestructiveHinted: destructive, requiredInputs: required)
    }

    func testToolNeedingNoInputIsAFeedCandidate() {
        XCTAssertTrue(info(required: []).isFeedCandidate)
    }

    func testToolRequiringInputIsNot() {
        // web_search_exa requires `query` — the case that prompted the rule.
        XCTAssertFalse(info(required: ["query"]).isFeedCandidate)
    }

    /// Codex P2: a no-argument `clear_cache()` would otherwise look like a
    /// perfect one-click card and then fire on every refresh forever.
    func testSelfDeclaredDestructiveToolIsNeverACandidate() {
        XCTAssertFalse(info(required: [], destructive: true).isFeedCandidate)
    }

    /// But an ABSENT read-only hint must not disqualify: annotations are
    /// optional and many servers omit them, so demanding the positive hint
    /// would silently hide legitimate read tools.
    func testMissingAnnotationsStillQualify() {
        XCTAssertTrue(info(required: [], readOnly: nil, destructive: nil).isFeedCandidate)
    }

    /// An EXPLICIT `readOnlyHint: false` is a server declaring that calling it
    /// mutates something. Putting that on a timer turns a deliberate one-off
    /// action into a repeated background write. (Codex round 3.)
    func testExplicitlyNonReadOnlyToolIsNotACandidate() {
        XCTAssertFalse(info(required: [], readOnly: false, destructive: nil).isFeedCandidate)
        XCTAssertFalse(info(required: [], readOnly: false, destructive: false).isFeedCandidate)
    }

    func testRequiredInputsAreReadOffTheJSONSchema() {
        let schema = Value.object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
        ])
        XCTAssertEqual(MCPToolInfo.requiredInputs(from: schema), ["query"])
    }

    /// Permissive read: a server that declares no requirements isn't claiming
    /// any, so it stays eligible rather than being hidden.
    func testMissingOrMalformedSchemaMeansNoRequirements() {
        XCTAssertEqual(MCPToolInfo.requiredInputs(from: nil), [])
        XCTAssertEqual(MCPToolInfo.requiredInputs(from: .object([:])), [])
        XCTAssertEqual(MCPToolInfo.requiredInputs(from: .string("nonsense")), [])
        XCTAssertEqual(
            MCPToolInfo.requiredInputs(from: .object(["required": .string("query")])), [])
    }

    /// Binding a tool that needs input should show what's missing, not `{}`
    /// followed by a -32602 the user has to decode.
    func testArgumentTemplatePrefillsTheRequiredShape() {
        XCTAssertEqual(MCPClientService.argumentTemplate(for: []), "{}")
        XCTAssertEqual(
            MCPClientService.argumentTemplate(for: ["query"]), #"{"query": ""}"#)
        XCTAssertEqual(
            MCPClientService.argumentTemplate(for: ["repo", "branch"]),
            #"{"repo": "", "branch": ""}"#)
    }
}

// MARK: - Config change signal (Codex P2: orphaned sources / stale bindings)

/// The coordinator snapshots its Sources at `start()`. Without a signal, a
/// removed server leaves an orphan poll loop publishing a "Not connected" card
/// for something that no longer exists, and an edited argument keeps calling
/// with the old value until an unrelated restart.
@MainActor
final class MCPFeedConfigChangeSignalTests: XCTestCase {
    private var service: MCPClientService!
    private var tempURL: URL!
    private var received = 0
    private var cancellable: AnyCancellable?

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-feedsignal-\(UUID().uuidString).json")
        service = MCPClientService(
            store: MCPServerConfigStore(fileURL: tempURL),
            secretStore: InMemoryMCPSecretStore(),
            connectionFactory: { _ in NeverConnection() }
        )
        received = 0
        cancellable = service.feedConfigDidChange.sink { [weak self] in self?.received += 1 }
    }

    override func tearDown() {
        cancellable = nil
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func addServer(allowed: Set<String> = ["list_issues"]) -> MCPServerConfig {
        var config = MCPServerConfig(
            id: UUID(), name: "Linear",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!))
        config.allowedTools = allowed
        service.addServer(config)
        return config
    }

    func testRemovingAServerSignalsSoTheOrphanSourceIsTornDown() {
        let config = addServer()
        received = 0
        service.removeServer(id: config.id)
        XCTAssertEqual(received, 1)
    }

    func testEditingArgumentsSignalsSoTheLiveSourceStopsUsingTheOldValue() {
        let config = addServer()
        service.setFeedTool(serverID: config.id, tool: "list_issues", bound: true)
        received = 0
        service.setFeedToolArguments(
            serverID: config.id, tool: "list_issues", argumentsJSON: #"{"assignee": "me"}"#)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(
            service.store.server(id: config.id)?.feedBindings.first?.argumentsJSON,
            #"{"assignee": "me"}"#)
    }

    func testBindingAndAllowlistChangesBothSignal() {
        let config = addServer()
        received = 0
        service.setFeedTool(serverID: config.id, tool: "list_issues", bound: true)
        XCTAssertEqual(received, 1)
        service.setToolAllowed(serverID: config.id, tool: "list_issues", allowed: false)
        XCTAssertEqual(received, 2)
    }

    /// The signal must NOT come from `objectWillChange` or a store-wide
    /// observer: `recordProbe`/`recordRun` call `store.update` on every connect
    /// and every tool call, which would restart the coordinator in a loop.
    func testProbeTelemetryDoesNotSignal() async {
        let config = addServer()
        received = 0
        await service.connect(id: config.id)  // writes lastProbe via store.update
        XCTAssertEqual(received, 0)
    }
}

/// Connects but advertises nothing — enough to exercise the probe write path.
private final class NeverConnection: MCPConnecting {
    func listTools() async throws -> [MCPToolInfo] { [] }
    func listFullTools() async throws -> [Tool] { [] }
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        MCPToolCallOutput(result: CallTool.Result(content: [], isError: false))
    }
    func ping() async throws {}
    func disconnect() async {}
}

/// Runs a closure in the middle of a tool call — the window where the caller's
/// pre-await config snapshot goes stale.
private final class InterleavingConnection: MCPConnecting {
    var duringCall: (@Sendable () async -> Void)?
    func listTools() async throws -> [MCPToolInfo] { [] }
    func listFullTools() async throws -> [Tool] { [] }
    func callTool(name: String, arguments: [String: Value]?) async throws -> MCPToolCallOutput {
        await duringCall?()
        return MCPToolCallOutput(result: CallTool.Result(content: [], isError: false))
    }
    func ping() async throws {}
    func disconnect() async {}
}

/// Codex round 3 P2: telemetry written after an await must not resurrect the
/// config as it was BEFORE the await.
@MainActor
final class MCPTelemetryClobberTests: XCTestCase {
    func testFeedEditDuringAToolCallSurvivesTheTelemetryWrite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-clobber-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let connection = InterleavingConnection()
        let service = MCPClientService(
            store: MCPServerConfigStore(fileURL: url),
            secretStore: InMemoryMCPSecretStore(),
            connectionFactory: { _ in connection })

        var config = MCPServerConfig(
            id: UUID(), name: "Exa",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!))
        config.allowedTools = ["web_search_exa"]
        config.feedTools = [MCPFeedToolBinding(tool: "web_search_exa", argumentsJSON: "{}")]
        service.addServer(config)
        await service.connect(id: config.id)

        // The user edits feed arguments WHILE the scheduled call is in flight.
        let serverID = config.id
        connection.duringCall = { @Sendable in
            await MainActor.run {
                service.setFeedToolArguments(
                    serverID: serverID, tool: "web_search_exa",
                    argumentsJSON: #"{"query": "macos"}"#)
            }
        }
        _ = try await service.callAllowedTool(
            serverID: config.id, name: "web_search_exa", arguments: [:])

        // recordRun runs after the await — it must not write back the snapshot
        // it captured before it.
        XCTAssertEqual(
            service.store.server(id: config.id)?.feedBindings.first?.argumentsJSON,
            #"{"query": "macos"}"#,
            "telemetry clobbered the user's feed edit")
    }

    /// A server removed mid-call must not be resurrected by its own trailing
    /// telemetry write.
    func testServerRemovedDuringACallIsNotResurrected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-clobber2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let connection = InterleavingConnection()
        let service = MCPClientService(
            store: MCPServerConfigStore(fileURL: url),
            secretStore: InMemoryMCPSecretStore(),
            connectionFactory: { _ in connection })

        var config = MCPServerConfig(
            id: UUID(), name: "Exa",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!))
        config.allowedTools = ["t"]
        service.addServer(config)
        await service.connect(id: config.id)

        let serverID = config.id
        connection.duringCall = { @Sendable in
            await MainActor.run { service.removeServer(id: serverID) }
        }
        _ = try? await service.callAllowedTool(serverID: serverID, name: "t", arguments: [:])

        XCTAssertNil(service.store.server(id: serverID))
    }
}

// MARK: - Config persistence

final class MCPFeedBindingConfigTests: XCTestCase {
    /// The trap this guards: `MCPServerConfigStore.load` decodes with `try?`, so
    /// a new NON-optional key would fail on every pre-GW-214 file and silently
    /// wipe the user's whole server list on upgrade.
    func testPreGW214ConfigStillDecodes() throws {
        let legacy = Data(
            """
            [{
              "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "name": "Linear",
              "transport": {"http": {"endpoint": "https://mcp.linear.app/mcp"}},
              "allowedTools": ["list_issues"],
              "isEnabled": true
            }]
            """.utf8)
        let decoded = try JSONDecoder().decode([MCPServerConfig].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].feedTools)
        XCTAssertTrue(decoded[0].feedBindings.isEmpty)
    }

    /// Binding is a second opt-in, never a way around the allowlist.
    func testBindingWithoutTheAllowlistIsInert() {
        var config = MCPServerConfig(
            id: UUID(), name: "Linear",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!))
        config.feedTools = [MCPFeedToolBinding(tool: "list_issues")]
        XCTAssertTrue(config.feedBindings.isEmpty)

        config.allowedTools = ["list_issues"]
        XCTAssertEqual(config.feedBindings.map(\.tool), ["list_issues"])
    }
}
