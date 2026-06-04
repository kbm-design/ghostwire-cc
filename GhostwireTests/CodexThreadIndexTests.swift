//
//  CodexThreadIndexTests.swift
//  GhostwireTests
//
//  GW-197: Codex's sqlite index (~/.codex/state_5.sqlite, `threads` table)
//  carries the thread title (set once by the launching surface - desktop app,
//  Codex Companion, computer-use) and the authoritative rollout_path.
//  The parser uses it for: (1) ConversationInfo.summary so Codex rows show
//  real titles like Codex's own UI; (2) rollout file resolution without
//  walking the Y/M/D tree. Both degrade gracefully when the db or row is
//  missing (pre-first-turn sessions have no thread row - verified vs 0.136.0).
//

import SQLite3
import XCTest
@testable import Ghostwire

final class CodexThreadIndexTests: XCTestCase {

    private let sessionId = "019e8bd5-aaaa-7681-8840-4830234ab001"
    private var tempRoot: String!
    private var dbPath: String!
    private var rolloutPath: String!

    private static let rolloutFixture = """
{"timestamp":"2026-06-03T21:00:00.000Z","type":"session_meta","payload":{"id":"019e8bd5-aaaa-7681-8840-4830234ab001","cwd":"/tmp"}}
{"timestamp":"2026-06-03T21:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"first message typed by the user"}}
{"timestamp":"2026-06-03T21:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"a reply"}}
"""

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "gw197-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)

        // Rollout lives OUTSIDE the Y/M/D layout - resolvable only via sqlite
        // rollout_path, proving the index is consulted before the tree walk.
        rolloutPath = tempRoot + "/flat-rollout-\(sessionId).jsonl"
        try Self.rolloutFixture.write(toFile: rolloutPath, atomically: true, encoding: .utf8)

        dbPath = tempRoot + "/state_5.sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT ''
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let insert = """
        INSERT INTO threads (id, rollout_path, title) VALUES
        ('\(sessionId)', '\(rolloutPath!)', 'Codex Companion Task: tidy the widgets');
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    private func makeParser() -> CodexTranscriptParser {
        CodexTranscriptParser(sessionsRoot: tempRoot + "/sessions", stateDBPath: dbPath, negativeCacheTTL: 0)
    }

    // MARK: - Titles

    func testSummaryComesFromSqliteTitle() async {
        let info = await makeParser().parse(sessionId: sessionId)
        XCTAssertEqual(info.summary, "Codex Companion Task: tidy the widgets")
        // firstUserMessage still parsed from the rollout as the fallback
        XCTAssertEqual(info.firstUserMessage, "first message typed by the user")
    }

    func testEmptyTitleLeavesSummaryNil() async throws {
        var db: OpaquePointer?
        sqlite3_open(dbPath, &db)
        sqlite3_exec(db, "UPDATE threads SET title = '';", nil, nil, nil)
        sqlite3_close(db)

        let info = await makeParser().parse(sessionId: sessionId)
        XCTAssertNil(info.summary, "empty sqlite title must fall back to firstUserMessage, not an empty string")
    }

    func testMissingDatabaseDegradesGracefully() async throws {
        try FileManager.default.removeItem(atPath: dbPath)
        // No sqlite, rollout outside the tree -> unresolvable, but must not crash
        let info = await makeParser().parse(sessionId: sessionId)
        XCTAssertNil(info.summary)
    }

    // MARK: - rollout_path resolution

    func testRolloutResolvedViaSqlitePathWithoutTreeWalk() async {
        // sessionsRoot subdir doesn't even exist - only sqlite can resolve this
        let path = await makeParser().rolloutFilePath(sessionId: sessionId)
        XCTAssertEqual(path, rolloutPath)
    }

    func testStaleSqlitePathFallsBackToTreeWalk() async throws {
        // sqlite points at a deleted file; the real rollout is in the Y/M/D tree
        try FileManager.default.removeItem(atPath: rolloutPath)
        let dayDir = tempRoot + "/sessions/2026/06/03"
        try FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
        let treePath = dayDir + "/rollout-2026-06-03T21-00-00-\(sessionId).jsonl"
        try Self.rolloutFixture.write(toFile: treePath, atomically: true, encoding: .utf8)

        let path = await makeParser().rolloutFilePath(sessionId: sessionId)
        XCTAssertEqual(path, treePath)
    }
}

// MARK: - Approval-row key normalization (GW-197 item 3)

final class PermissionContextFormattingTests: XCTestCase {

    func testCodexCmdKeyDisplaysAsCommand() {
        let ctx = PermissionContext(
            toolUseId: "call_x",
            toolName: "exec_command",
            toolInput: ["cmd": AnyCodable("defaults read com.manaflow.cmux")],
            receivedAt: Date()
        )
        XCTAssertEqual(ctx.formattedInput?.contains("command: defaults read com.manaflow.cmux"), true)
        XCTAssertEqual(ctx.formattedInput?.contains("cmd:"), false,
                       "Codex's cmd key must render as command, matching Claude rows")
    }

    func testClaudeCommandKeyUnchanged() {
        let ctx = PermissionContext(
            toolUseId: "toolu_x",
            toolName: "Bash",
            toolInput: ["command": AnyCodable("cd /tmp")],
            receivedAt: Date()
        )
        XCTAssertEqual(ctx.formattedInput?.contains("command: cd /tmp"), true)
    }
}
