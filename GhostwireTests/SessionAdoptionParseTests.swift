//
//  SessionAdoptionParseTests.swift
//  GhostwireTests
//
//  GW-194 (and the suspected GW-193 fix): parse ConversationInfo when a
//  session is ADOPTED — registered from a discovery snapshot or created by
//  its first hook event — instead of waiting for a file-sync event. Idle
//  pre-existing sessions never produce sync events, so without the adoption
//  parse their titles stay stuck on the folder name.
//
//  ConversationParser resolves transcripts under the real ~/.claude/projects,
//  so these tests write fixtures there in a uniquely-named project dir (the
//  encoded cwd is a per-test temp path) and remove it in tearDown.
//

import XCTest
@testable import Ghostwire

final class SessionAdoptionParseTests: XCTestCase {

    private var cwd: String!
    private var projectDir: String!

    override func setUpWithError() throws {
        cwd = "/tmp/gw194-adopt-" + UUID().uuidString.lowercased()
        let encoded = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        projectDir = NSHomeDirectory() + "/.claude/projects/" + encoded
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: projectDir)
    }

    private func writeTranscript(sessionId: String, title: String) throws {
        let lines = [
            #"{"type":"summary","summary":"\#(title)","leafUuid":"aaaa"}"#,
            #"{"parentUuid":null,"isSidechain":false,"cwd":"\#(cwd!)","sessionId":"\#(sessionId)","type":"user","message":{"role":"user","content":"please fix the login flow"},"timestamp":"2026-06-04T10:00:00.000Z"}"#,
        ]
        try lines.joined(separator: "\n")
            .write(toFile: projectDir + "/" + sessionId + ".jsonl", atomically: true, encoding: .utf8)
    }

    func testDiscoveredClaudeSessionGetsTitleAtAdoption() async throws {
        let sessionId = UUID().uuidString.lowercased()
        try writeTranscript(sessionId: sessionId, title: "Fix the login flow")

        await SessionStore.shared.process(.sessionsDiscovered([
            DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                agent: "claude",
                transcriptPath: projectDir + "/" + sessionId + ".jsonl",
                fileModified: Date()
            )
        ]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.conversationInfo.summary, "Fix the login flow",
                       "provisional sessions must get their title at adoption, not on a sync that never comes")
        XCTAssertEqual(session?.displayTitle, "Fix the login flow")
    }

    func testNewHookSessionGetsTitleAtAdoption() async throws {
        // GW-193: a session registering via an event that does NOT trigger a
        // file sync (e.g. Notification) stayed stuck on the folder name.
        let sessionId = UUID().uuidString.lowercased()
        try writeTranscript(sessionId: sessionId, title: "Refactor the parser")

        await SessionStore.shared.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: "Notification",
            status: "idle",
            pid: 4242,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            source: "claude"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.conversationInfo.summary, "Refactor the parser",
                       "first hook event must parse the title even when it never syncs the file")
    }

    func testAdoptionOnlyFillsEmptyConversationInfo() async throws {
        // Codex review (PR #21): the adoption parse resolves after an await,
        // so a concurrent file sync can populate conversationInfo first. The
        // late adoption write must yield instead of clobbering fresher state.
        let sessionId = UUID().uuidString.lowercased()
        try writeTranscript(sessionId: sessionId, title: "Original title")

        await SessionStore.shared.process(.sessionsDiscovered([
            DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                agent: "claude",
                transcriptPath: projectDir + "/" + sessionId + ".jsonl",
                fileModified: Date()
            )
        ]))

        // Simulate a late-resolving adoption racing already-populated info:
        // the transcript now parses to a different title, but the session's
        // info is no longer empty, so re-adoption must not overwrite it.
        try writeTranscript(sessionId: sessionId, title: "Late-arriving title")
        await SessionStore.shared.adoptConversationInfo(
            sessionId: sessionId, agent: "claude", cwd: cwd
        )

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.conversationInfo.summary, "Original title",
                       "adoption must only fill empty info, never overwrite richer state")
    }
}
