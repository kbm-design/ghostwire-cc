//
//  SessionAgentIdentityTests.swift
//  GhostwireTests
//
//  GW-341: a session's `agent` used to be stamped once, at creation, and never
//  revisited. Whichever path registered the row first owned its identity for
//  life — so a row adopted through discovery (which infers the agent from which
//  directory a transcript sits in, and only knows claude/codex) kept that guess
//  even after hook events arrived saying otherwise.
//
//  The hook's `source` is stamped by the installer that wrote the hook
//  (GHOSTWIRE_AGENT=cursor|codex|…), so it is the authoritative answer and must
//  win on every event that carries one.
//

import XCTest
@testable import Ghostwire

final class SessionAgentIdentityTests: XCTestCase {

    private func uniqueSessionId() -> String { UUID().uuidString.lowercased() }

    private func hookEvent(
        _ sessionId: String,
        event: String = "UserPromptSubmit",
        status: String = "processing",
        source: String?
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw341-identity-tests",
            event: event,
            status: status,
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            source: source
        )
    }

    private func agent(of sessionId: String) async -> String? {
        await SessionStore.shared.session(for: sessionId)?.agent
    }

    func testHookSourceStampsAgentOnCreation() async {
        let id = uniqueSessionId()
        await SessionStore.shared.process(.hookReceived(hookEvent(id, source: "cursor")))

        let stamped = await agent(of: id)
        XCTAssertEqual(stamped, "cursor")
        XCTAssertEqual(AgentIdentity.tint(for: stamped), AgentIdentity.cursor)
    }

    /// The bug shape: discovery registers the row (it can only ever guess
    /// "claude" or "codex"), then the real agent's hook event arrives. Before
    /// the fix the discovery guess survived and the row wore Claude's tag and
    /// tint for the rest of the session.
    func testHookSourceCorrectsAnAgentInheritedFromDiscovery() async {
        let id = uniqueSessionId()
        await SessionStore.shared.process(.sessionsDiscovered([
            DiscoveredSession(
                sessionId: id,
                cwd: "/tmp/gw341-identity-tests",
                agent: "claude",
                transcriptPath: "/tmp/gw341-identity-tests/\(id).jsonl",
                fileModified: Date()
            )
        ]))
        let beforeHook = await agent(of: id)
        XCTAssertEqual(beforeHook, "claude", "precondition: provisional starts as discovery guessed")

        await SessionStore.shared.process(.hookReceived(hookEvent(id, source: "cursor")))

        let corrected = await agent(of: id)
        XCTAssertEqual(corrected, "cursor")
    }

    /// The correction is not one-shot: a later event must not be able to
    /// re-stamp the row from a stale value either.
    func testLaterEventsKeepTheAgentStable() async {
        let id = uniqueSessionId()
        await SessionStore.shared.process(.hookReceived(hookEvent(id, source: "cursor")))
        await SessionStore.shared.process(.hookReceived(
            hookEvent(id, event: "Stop", status: "waiting_for_input", source: "cursor")
        ))

        let stable = await agent(of: id)
        XCTAssertEqual(stable, "cursor")
    }

    /// An event with no source (older hook script, hand-rolled integration)
    /// must not erase an identity we already know.
    func testSourcelessEventDoesNotClearAKnownAgent() async {
        let id = uniqueSessionId()
        await SessionStore.shared.process(.hookReceived(hookEvent(id, source: "cursor")))
        await SessionStore.shared.process(.hookReceived(
            hookEvent(id, event: "Stop", status: "waiting_for_input", source: nil)
        ))

        let preserved = await agent(of: id)
        XCTAssertEqual(preserved, "cursor")
    }

    /// Unknown agent renders neutral, never a vendor's colour.
    func testUnknownAgentTintIsNeutral() {
        XCTAssertEqual(AgentIdentity.tint(for: nil), AgentIdentity.neutral)
        XCTAssertEqual(AgentIdentity.tint(for: ""), AgentIdentity.neutral)
        XCTAssertEqual(AgentIdentity.tint(for: "some-future-agent"), AgentIdentity.neutral)
        XCTAssertEqual(AgentIdentity.tint(for: "cursor"), AgentIdentity.cursor)
    }
}
