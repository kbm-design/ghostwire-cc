//
//  SessionDiscoveryServiceTests.swift
//  GhostwireTests
//
//  GW-194: launch-time session discovery. Sessions only register when a hook
//  event arrives, so transcripts that predate hook install (or were idle at
//  app launch) are invisible. SessionDiscoveryService scans the transcript
//  trees directly:
//    Claude: ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl
//    Codex:  ~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl
//
//  cwd comes from transcript content (the encoded dirname is lossy — "/" and
//  "." both encode to "-"); the dirname decode is only a fallback.
//

import XCTest
@testable import Ghostwire

final class SessionDiscoveryServiceTests: XCTestCase {

    private var claudeRoot: String!
    private var codexRoot: String!

    private let claudeSessionId = "11111111-2222-3333-4444-555555555555"
    private let codexSessionId = "019e8bd5-369f-7681-8840-4830234ab673"

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "gw194-tests-" + UUID().uuidString
        claudeRoot = base + "/claude-projects"
        codexRoot = base + "/codex-sessions"
        try FileManager.default.createDirectory(atPath: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (claudeRoot as NSString).deletingLastPathComponent)
    }

    private func makeService(
        maxAge: TimeInterval = 24 * 3600,
        gate: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> SessionDiscoveryService {
        SessionDiscoveryService(
            claudeProjectsRoot: claudeRoot,
            codexSessionsRoot: codexRoot,
            maxAge: maxAge,
            isAgentProcessAlive: gate
        )
    }

    // MARK: - Fixtures

    /// Minimal Claude transcript. Mirrors the real shape: leading non-message
    /// lines without a cwd, then entries that carry one.
    private func writeClaudeTranscript(
        sessionId: String,
        projectDirName: String,
        cwd: String?,
        modified: Date? = nil
    ) throws -> String {
        let dir = claudeRoot + "/" + projectDirName
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + sessionId + ".jsonl"

        var lines = [
            #"{"type":"summary","summary":"Fix the login flow","leafUuid":"aaaa"}"#,
            #"{"type":"last-prompt","sessionId":"\#(sessionId)"}"#,
        ]
        if let cwd {
            lines.append(
                #"{"parentUuid":null,"isSidechain":false,"cwd":"\#(cwd)","sessionId":"\#(sessionId)","type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-06-04T10:00:00.000Z"}"#
            )
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    /// Minimal Codex rollout with a session_meta first line.
    private func writeCodexRollout(
        sessionId: String,
        cwd: String?,
        modified: Date? = nil
    ) throws -> String {
        let dayDir = codexRoot + "/2026/06/04"
        try FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
        let path = dayDir + "/rollout-2026-06-04T09-00-00-\(sessionId).jsonl"

        var lines: [String] = []
        if let cwd {
            lines.append(
                #"{"timestamp":"2026-06-04T09:00:00.000Z","type":"session_meta","payload":{"id":"\#(sessionId)","cwd":"\#(cwd)","originator":"codex_cli_rs","cli_version":"0.136.0"}}"#
            )
        }
        lines.append(
            #"{"timestamp":"2026-06-04T09:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#
        )
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    // MARK: - Claude discovery

    func testDiscoversRecentClaudeSessionWithCwdFromTranscript() async throws {
        _ = try writeClaudeTranscript(
            sessionId: claudeSessionId,
            projectDirName: "-Users-test-my-app",
            cwd: "/Users/test/my.app"  // dot would be lost by dirname decoding
        )

        let sessions = await makeService().discoverSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, claudeSessionId)
        XCTAssertEqual(sessions.first?.agent, "claude")
        XCTAssertEqual(sessions.first?.cwd, "/Users/test/my.app",
                       "cwd must come from transcript content, not the lossy dirname")
    }

    func testClaudeCwdFallsBackToDecodedDirectoryName() async throws {
        _ = try writeClaudeTranscript(
            sessionId: claudeSessionId,
            projectDirName: "-Users-test-my-app",
            cwd: nil  // no cwd anywhere in the file
        )

        let sessions = await makeService().discoverSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.cwd, "/Users/test/my/app")
    }

    func testIgnoresAgentFilesDirectoriesAndNonUUIDNames() async throws {
        _ = try writeClaudeTranscript(
            sessionId: claudeSessionId,
            projectDirName: "-Users-test-my-app",
            cwd: "/Users/test/my-app"
        )
        let dir = claudeRoot + "/-Users-test-my-app"
        // Subagent transcript: agent-<id>.jsonl must not register as a session
        try "{}".write(toFile: dir + "/agent-\(claudeSessionId).jsonl", atomically: true, encoding: .utf8)
        // Sidecar directory named like a session UUID (exists in real trees)
        try FileManager.default.createDirectory(
            atPath: dir + "/99999999-8888-7777-6666-555555555555", withIntermediateDirectories: true)
        // Non-UUID jsonl
        try "{}".write(toFile: dir + "/notes.jsonl", atomically: true, encoding: .utf8)

        let sessions = await makeService().discoverSessions()

        XCTAssertEqual(sessions.map(\.sessionId), [claudeSessionId])
    }

    func testIgnoresClaudeTranscriptsOlderThanCutoff() async throws {
        _ = try writeClaudeTranscript(
            sessionId: claudeSessionId,
            projectDirName: "-Users-test-my-app",
            cwd: "/Users/test/my-app",
            modified: Date(timeIntervalSinceNow: -48 * 3600)
        )

        let sessions = await makeService(maxAge: 24 * 3600).discoverSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Codex discovery

    func testDiscoversCodexRolloutWithCwdFromSessionMeta() async throws {
        _ = try writeCodexRollout(sessionId: codexSessionId, cwd: "/Users/test/work")

        let sessions = await makeService().discoverSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, codexSessionId)
        XCTAssertEqual(sessions.first?.agent, "codex")
        XCTAssertEqual(sessions.first?.cwd, "/Users/test/work")
    }

    func testIgnoresCodexRolloutsOlderThanCutoff() async throws {
        _ = try writeCodexRollout(
            sessionId: codexSessionId,
            cwd: "/Users/test/work",
            modified: Date(timeIntervalSinceNow: -48 * 3600)
        )

        let sessions = await makeService(maxAge: 24 * 3600).discoverSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    func testCodexRolloutWithoutSessionMetaIsSkipped() async throws {
        // No session_meta -> no cwd -> can't build a useful session row
        _ = try writeCodexRollout(sessionId: codexSessionId, cwd: nil)

        let sessions = await makeService().discoverSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Process gate

    func testProcessGateExcludesAgentsWithNoLiveProcess() async throws {
        _ = try writeClaudeTranscript(
            sessionId: claudeSessionId,
            projectDirName: "-Users-test-my-app",
            cwd: "/Users/test/my-app"
        )
        _ = try writeCodexRollout(sessionId: codexSessionId, cwd: "/Users/test/work")

        // No claude process running -> every claude transcript is provably dead
        let sessions = await makeService(gate: { agent in agent == "codex" }).discoverSessions()

        XCTAssertEqual(sessions.map(\.agent), ["codex"])
    }

    // MARK: - Edge cases

    func testMissingRootsYieldEmpty() async {
        let service = SessionDiscoveryService(
            claudeProjectsRoot: claudeRoot + "/nope",
            codexSessionsRoot: codexRoot + "/nope",
            maxAge: 24 * 3600,
            isAgentProcessAlive: { _ in true }
        )

        let sessions = await service.discoverSessions()

        XCTAssertTrue(sessions.isEmpty)
    }
}
