//
//  AgentTargetSelectionTests.swift
//  GhostwireTests
//
//  GW-164 (B): send-to-agent target resolution.
//
//  Pure selection seam: given the live sessions and which one is focused, pick
//  the target. One live -> it's the target; a focused one among many -> the
//  focused; several with none focused -> candidates for the picker; none -> no
//  target. `liveSessions` gates on a usable DELIVERY PATH (tiered, AGENTS.md):
//  a mux-addressable pane OR a focusable plain terminal (baseline, needs a
//  pid). Addressability picks the tier, not eligibility — a lone plain terminal
//  must still be a target. Ended / no-pid sessions are never targets.
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

    // MARK: - liveSessions gate (delivery path + tier)

    func testLiveSessionsResolvesTierPerDeliveryPath() {
        let cmuxOk = makeSession(id: "cmux", isInCmux: true, ws: "workspace:1", surface: "surface:1")
        let tmuxOk = makeSession(id: "tmux", isInTmux: true, tty: "ttys003")
        let cmuxNoRefs = makeSession(id: "cmuxbad", isInCmux: true)   // refs missing -> baseline via pid
        let plain = makeSession(id: "plain")                          // plain terminal -> baseline via pid

        let live = AgentTargetResolver.liveSessions(from: [cmuxOk, tmuxOk, cmuxNoRefs, plain])
        XCTAssertEqual(live.map(\.session.sessionId), ["cmux", "tmux", "cmuxbad", "plain"])
        XCTAssertEqual(
            live.map(\.tier),
            [.multiplexer, .multiplexer, .baseline, .baseline],
            "addressable panes take the mux tier; everything with a pid falls back to baseline"
        )
    }

    func testLiveSessionsDropsSessionsWithNoDeliveryPath() {
        // No mux pane AND no pid -> nothing to focus or address -> not a target.
        let orphan = makeSession(id: "orphan", pid: nil)
        let live = AgentTargetResolver.liveSessions(from: [orphan])
        XCTAssertTrue(live.isEmpty)
    }

    func testLiveSessionsDropsEndedSessions() {
        let ended = makeSession(id: "ended", isInCmux: true, ws: "w", surface: "s", phase: .ended)
        let alive = makeSession(id: "alive", isInCmux: true, ws: "w", surface: "s")
        let live = AgentTargetResolver.liveSessions(from: [ended, alive])
        XCTAssertEqual(live.map(\.session.sessionId), ["alive"])
    }

    // MARK: - baseline eligibility (the house-rule case)

    func testSinglePlainTerminalSessionIsTheTarget() async {
        // The required baseline: one ordinary terminal, no tmux/cmux. It MUST
        // resolve to a target (regression for the dropped-plain-terminal bug).
        let plain = makeSession(id: "plain")
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [plain],
            isFocused: { _ in false }
        )
        XCTAssertEqual(target, .single(sessionId: "plain"))
    }

    func testMixedMuxAndPlainBothLiveYieldCandidates() async {
        let mux = makeSession(id: "mux", isInCmux: true, ws: "w", surface: "s")
        let plain = makeSession(id: "plain")
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [mux, plain],
            isFocused: { _ in false }
        )
        XCTAssertEqual(target, .candidates(sessionIds: ["mux", "plain"]))
    }

    func testMixedMuxAndPlainPicksFocusedPlain() async {
        let mux = makeSession(id: "mux", isInCmux: true, ws: "w", surface: "s")
        let plain = makeSession(id: "plain")
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [mux, plain],
            isFocused: { $0.sessionId == "plain" }
        )
        XCTAssertEqual(target, .focused(sessionId: "plain"))
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

    func testResolveActiveTargetIgnoresSessionsWithNoDeliveryPath() async {
        let live = makeSession(id: "live", isInCmux: true, ws: "w", surface: "s")
        let dead = makeSession(id: "dead", pid: nil)  // no pane, no pid -> no path
        let target = await AgentTargetResolver.resolveActiveTarget(
            from: [dead, live],
            isFocused: { _ in false }
        )
        // only one deliverable -> single, no picker
        XCTAssertEqual(target, .single(sessionId: "live"))
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        pid: Int? = 1234,
        isInTmux: Bool = false,
        isInCmux: Bool = false,
        ws: String? = nil,
        surface: String? = nil,
        tty: String? = nil,
        agent: String? = "claude",
        phase: SessionPhase = .idle
    ) -> SessionState {
        var session = SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            pid: pid,
            tty: tty,
            isInTmux: isInTmux,
            isInCmux: isInCmux,
            agent: agent,
            phase: phase
        )
        session.cmuxWorkspaceRef = ws
        session.cmuxSurfaceRef = surface
        return session
    }
}
