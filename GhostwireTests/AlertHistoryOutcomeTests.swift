//
//  AlertHistoryOutcomeTests.swift
//  GhostwireTests
//
//  GW-207 alert-history v2: forward-compatible decode of v1 JSON, outcome
//  matching (allow/deny/timeout stamps the right alert), ready→responded
//  gating, and the record-time row inputs (folder / command summary). Pure
//  seams only — the store helpers are nonisolated static.
//

import XCTest
@testable import Ghostwire

final class AlertHistoryOutcomeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Forward-compatible decode (GW-207 4a)

    func testV1JSONWithoutNewFieldsDecodes() throws {
        // v1 persisted shape: no folder/command/outcome/toolUseId keys.
        let iso = ISO8601DateFormatter().string(from: now)
        let json = #"""
        [{"id":"\#(UUID().uuidString)","date":"\#(iso)","agent":"claude","sessionId":"s1","kind":"permission","detail":"Bash"}]
        """#
        let alerts = try decoder().decode([AgentAlert].self, from: Data(json.utf8))

        XCTAssertEqual(alerts.count, 1)
        let a = alerts[0]
        XCTAssertEqual(a.kind, "permission")
        XCTAssertNil(a.folder)
        XCTAssertNil(a.command)
        XCTAssertNil(a.outcome)
        XCTAssertNil(a.toolUseId)
    }

    func testNewFieldsRoundTrip() throws {
        let original = AgentAlert(
            id: UUID(), date: now, agent: "codex", sessionId: "s1",
            kind: "permission", detail: "Bash",
            folder: "ghostwire", command: "ls -la", outcome: "allowed", toolUseId: "t1"
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode([original])
        let decoded = try decoder().decode([AgentAlert].self, from: data)
        XCTAssertEqual(decoded.first, original)
    }

    // MARK: - Permission outcome matching (GW-207 4c)

    private func permission(
        toolUseId: String, sessionId: String = "s1",
        ageSeconds: TimeInterval = 0, outcome: String? = nil
    ) -> AgentAlert {
        AgentAlert(
            id: UUID(), date: now.addingTimeInterval(-ageSeconds),
            agent: "claude", sessionId: sessionId, kind: "permission",
            detail: "Bash", folder: "ghostwire", command: "ls",
            outcome: outcome, toolUseId: toolUseId
        )
    }

    func testOutcomeStampsMatchingAlert() {
        let alerts = [permission(toolUseId: "t1"), permission(toolUseId: "t2")]
        let result = AlertHistoryStore.applyingPermissionOutcome(
            to: alerts, sessionId: "s1", toolUseId: "t2", outcome: "allowed"
        )
        XCTAssertNotNil(result)
        XCTAssertNil(result?[0].outcome)
        XCTAssertEqual(result?[1].outcome, "allowed")
    }

    func testOutcomeUpdatesOnlyMostRecentMatch() {
        // Two alerts share a tool_use_id (e.g. a re-requested permission).
        // Only the most recent unresolved one gets stamped, not both.
        let older = permission(toolUseId: "t1", ageSeconds: 100)
        let newer = permission(toolUseId: "t1", ageSeconds: 1)
        let result = AlertHistoryStore.applyingPermissionOutcome(
            to: [older, newer], sessionId: "s1", toolUseId: "t1", outcome: "denied"
        )
        XCTAssertNil(result?[0].outcome)            // older untouched
        XCTAssertEqual(result?[1].outcome, "denied") // newer stamped
    }

    func testOutcomeSkipsAlreadyResolved() {
        // Already-allowed alert is not re-stamped; no second unresolved match → nil.
        let alerts = [permission(toolUseId: "t1", outcome: "allowed")]
        let result = AlertHistoryStore.applyingPermissionOutcome(
            to: alerts, sessionId: "s1", toolUseId: "t1", outcome: "denied"
        )
        XCTAssertNil(result)
    }

    func testOutcomeNoMatchReturnsNil() {
        let alerts = [permission(toolUseId: "t1")]
        XCTAssertNil(AlertHistoryStore.applyingPermissionOutcome(
            to: alerts, sessionId: "s1", toolUseId: "nope", outcome: "allowed"
        ))
        XCTAssertNil(AlertHistoryStore.applyingPermissionOutcome(
            to: alerts, sessionId: "other", toolUseId: "t1", outcome: "allowed"
        ))
    }

    // MARK: - Ready → responded gating (GW-207 4c)

    private func ready(sessionId: String = "s1", ageSeconds: TimeInterval, outcome: String? = nil) -> AgentAlert {
        AgentAlert(
            id: UUID(), date: now.addingTimeInterval(-ageSeconds),
            agent: "claude", sessionId: sessionId, kind: "ready",
            detail: nil, folder: "ghostwire", outcome: outcome
        )
    }

    func testReadyRespondedMarksAlertBeforeUserMessage() {
        let alert = ready(ageSeconds: 60)                 // raised at now-60
        let userMsg = now                                 // reply at now
        let result = AlertHistoryStore.applyingReadyResponded(
            to: [alert], sessionId: "s1", before: userMsg
        )
        XCTAssertEqual(result?[0].outcome, "responded")
    }

    func testReadyRespondedIgnoresAlertAfterUserMessage() {
        // A ready alert raised AFTER the user message is a fresh ping the user
        // hasn't replied to — it must stay unanswered.
        let alert = ready(ageSeconds: 0)                  // raised at now
        let userMsg = now.addingTimeInterval(-60)         // reply was earlier
        let result = AlertHistoryStore.applyingReadyResponded(
            to: [alert], sessionId: "s1", before: userMsg
        )
        XCTAssertNil(result)
    }

    func testReadyRespondedPicksMostRecentEligible() {
        let older = ready(ageSeconds: 200)
        let newer = ready(ageSeconds: 100)
        let userMsg = now
        let result = AlertHistoryStore.applyingReadyResponded(
            to: [older, newer], sessionId: "s1", before: userMsg
        )
        XCTAssertNil(result?[0].outcome)
        XCTAssertEqual(result?[1].outcome, "responded")
    }

    func testReadyRespondedSkipsOtherSessions() {
        let alert = ready(sessionId: "other", ageSeconds: 60)
        let result = AlertHistoryStore.applyingReadyResponded(
            to: [alert], sessionId: "s1", before: now
        )
        XCTAssertNil(result)
    }

    // MARK: - Row inputs (GW-207 4b: folder + command summary)

    func testFolderNameExtractsLastPathComponent() {
        let session = SessionState(sessionId: "s1", cwd: "/Users/x/Code/ghostwire")
        XCTAssertEqual(session.folderName, "ghostwire")
    }

    func testCommandSummaryPrefersCommandKeySingleLine() {
        let ctx = PermissionContext(
            toolUseId: "t1", toolName: "Bash",
            toolInput: ["command": AnyCodable("echo hi\nls -la")],
            receivedAt: now
        )
        // command value wins, newlines collapse to spaces (single line for the row).
        XCTAssertEqual(ctx.commandSummary, "echo hi ls -la")
    }

    func testCommandSummaryNormalizesCodexCmdKey() {
        let ctx = PermissionContext(
            toolUseId: "t1", toolName: "exec_command",
            toolInput: ["cmd": AnyCodable("git status")],
            receivedAt: now
        )
        XCTAssertEqual(ctx.commandSummary, "git status")
    }
}
