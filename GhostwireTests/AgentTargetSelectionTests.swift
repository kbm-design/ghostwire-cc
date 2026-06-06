//
//  AgentTargetSelectionTests.swift
//  GhostwireTests
//
//  GW-164 (B): send-to-agent target resolution.
//
//  Pure selection seam: given the live (addressable) sessions and which one is
//  focused, pick the target. One live -> it's the target; a focused one among
//  many -> the focused; several with none focused -> candidates for the picker;
//  none -> no target. `liveSessions` gates on actual pane addressability
//  (mirrors the GW-162 chat-input gate), not process-tree flags.
//

import XCTest
@testable import Ghostwire

final class AgentTargetSelectionTests: XCTestCase {

    // MARK: - selectTarget

    func testNoLiveSessionsIsNone() {
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: [], focusedSessionId: nil),
            .none
        )
    }

    func testSingleLiveSessionIsTheTarget() {
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: ["s1"], focusedSessionId: nil),
            .single(sessionId: "s1")
        )
    }

    func testSingleLiveSessionWinsEvenIfNotFlaggedFocused() {
        // one session: never needs a focus probe
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: ["s1"], focusedSessionId: "other"),
            .single(sessionId: "s1")
        )
    }

    func testFocusedAmongManyPicksFocused() {
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: ["s1", "s2", "s3"], focusedSessionId: "s2"),
            .focused(sessionId: "s2")
        )
    }

    func testManyWithNoneFocusedReturnsCandidatesInOrder() {
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: ["s1", "s2", "s3"], focusedSessionId: nil),
            .candidates(sessionIds: ["s1", "s2", "s3"])
        )
    }

    func testFocusedSessionNotAmongLiveFallsBackToCandidates() {
        // the focused terminal isn't one of the addressable agent sessions
        XCTAssertEqual(
            AgentTargetResolver.selectTarget(liveSessionIds: ["s1", "s2"], focusedSessionId: "ghost"),
            .candidates(sessionIds: ["s1", "s2"])
        )
    }

    func testResolvedSessionIdOnlyForUnambiguous() {
        XCTAssertEqual(AgentTarget.single(sessionId: "s1").resolvedSessionId, "s1")
        XCTAssertEqual(AgentTarget.focused(sessionId: "s2").resolvedSessionId, "s2")
        XCTAssertNil(AgentTarget.candidates(sessionIds: ["s1", "s2"]).resolvedSessionId)
        XCTAssertNil(AgentTarget.none.resolvedSessionId)
    }

    // MARK: - liveSessions gate (pane addressability)

    func testLiveSessionsKeepsOnlyAddressablePanes() {
        let cmuxOk = makeSession(id: "cmux", isInCmux: true, ws: "workspace:1", surface: "surface:1")
        let tmuxOk = makeSession(id: "tmux", isInTmux: true, tty: "ttys003")
        let cmuxNoRefs = makeSession(id: "cmuxbad", isInCmux: true)   // refs missing -> unresolvable
        let plain = makeSession(id: "plain")                          // no multiplexer -> unresolvable

        let live = AgentTargetResolver.liveSessions(from: [cmuxOk, tmuxOk, cmuxNoRefs, plain])
        XCTAssertEqual(live.map(\.sessionId), ["cmux", "tmux"])
    }

    // MARK: - resolveActiveTarget (focus probe injected)

    func testResolveActiveTargetSingleSkipsFocusProbe() async {
        let only = makeSession(id: "only", isInCmux: true, ws: "w", surface: "s")
        var probed = false
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [only],
            isFocused: { _ in probed = true; return true }
        )
        XCTAssertEqual(target, .single(sessionId: "only"))
        XCTAssertFalse(probed, "single live session must not trigger a focus probe")
    }

    func testResolveActiveTargetPicksFocusedAmongMany() async {
        let a = makeSession(id: "a", isInTmux: true, tty: "ttys001")
        let b = makeSession(id: "b", isInTmux: true, tty: "ttys002")
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [a, b],
            isFocused: { $0.sessionId == "b" }
        )
        XCTAssertEqual(target, .focused(sessionId: "b"))
    }

    func testResolveActiveTargetNoneFocusedYieldsCandidates() async {
        let a = makeSession(id: "a", isInTmux: true, tty: "ttys001")
        let b = makeSession(id: "b", isInTmux: true, tty: "ttys002")
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [a, b],
            isFocused: { _ in false }
        )
        XCTAssertEqual(target, .candidates(sessionIds: ["a", "b"]))
    }

    func testResolveActiveTargetIgnoresUnaddressableSessions() async {
        let live = makeSession(id: "live", isInCmux: true, ws: "w", surface: "s")
        let dead = makeSession(id: "dead")  // plain, unresolvable
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [dead, live],
            isFocused: { _ in false }
        )
        // only one addressable -> single, no picker
        XCTAssertEqual(target, .single(sessionId: "live"))
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        isInTmux: Bool = false,
        isInCmux: Bool = false,
        ws: String? = nil,
        surface: String? = nil,
        tty: String? = nil,
        agent: String? = "claude"
    ) -> SessionState {
        var session = SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            pid: 1234,
            tty: tty,
            isInTmux: isInTmux,
            isInCmux: isInCmux,
            agent: agent
        )
        session.cmuxWorkspaceRef = ws
        session.cmuxSurfaceRef = surface
        return session
    }
}
