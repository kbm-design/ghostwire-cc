//
//  NotchRevealMachineTests.swift
//  GhostwireTests
//
//  GW-264 / GW-227: the auto-reveal dwell timer is a pure state machine —
//  start on reveal, pause on hover, restart on mouse-out, collapse on expiry.
//  Informational reveals collapse to nothing; actionable (pending approval)
//  reveals collapse "to glow" (toGlow:true) — the pending request is never
//  dropped, it recedes to the passive badge. No timers / AppKit / Combine here;
//  a thin @MainActor driver maps the emitted Effects onto real work.
//

import XCTest
@testable import Ghostwire

final class NotchRevealMachineTests: XCTestCase {

    // MARK: - Start

    func testRevealInformationalStartsDwellTimer() {
        var m = NotchRevealMachine()
        let effect = m.handle(.reveal(.informational))
        XCTAssertEqual(m.state, .dwelling(.informational))
        XCTAssertEqual(effect, .startTimer(.informational))
    }

    func testRevealActionableStartsDwellTimer() {
        var m = NotchRevealMachine()
        let effect = m.handle(.reveal(.actionable))
        XCTAssertEqual(m.state, .dwelling(.actionable))
        XCTAssertEqual(effect, .startTimer(.actionable))
    }

    // MARK: - Pause on hover, restart on mouse-out (WCAG 2.2.1)

    func testHoverPausesTheTimer() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        let effect = m.handle(.hoverChanged(true))
        XCTAssertEqual(m.state, .paused(.informational))
        XCTAssertEqual(effect, .cancelTimer)
    }

    func testMouseOutRestartsTheTimer() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.actionable))
        _ = m.handle(.hoverChanged(true))
        let effect = m.handle(.hoverChanged(false))
        XCTAssertEqual(m.state, .dwelling(.actionable))
        XCTAssertEqual(effect, .startTimer(.actionable))
    }

    // MARK: - Expire → collapse (info vs actionable)

    func testInformationalExpiryCollapsesToNothing() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        let effect = m.handle(.timerFired)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effect, .collapse(toGlow: false))
    }

    func testActionableExpiryCollapsesToGlow() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.actionable))
        let effect = m.handle(.timerFired)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effect, .collapse(toGlow: true))
    }

    func testTimerFiredWhilePausedIsIgnored() {
        // A stale fire after a pause must NOT collapse the notch out from
        // under a user who is hovering it.
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.actionable))
        _ = m.handle(.hoverChanged(true))
        let effect = m.handle(.timerFired)
        XCTAssertEqual(m.state, .paused(.actionable))
        XCTAssertEqual(effect, .none)
    }

    // MARK: - User takeover / external close cancels the dwell

    func testEngagedCancelsTheDwell() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.actionable))
        let effect = m.handle(.engaged)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effect, .cancelTimer)
    }

    func testDismissedCancelsTheDwell() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        let effect = m.handle(.dismissed)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effect, .cancelTimer)
    }

    func testEngagedWhileIdleIsANoOp() {
        var m = NotchRevealMachine()
        let effect = m.handle(.engaged)
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(effect, .none)
    }

    // MARK: - Upgrade / hover-while-paused edge cases

    func testActionableRevealUpgradesAnInformationalDwell() {
        // An approval arriving during an info reveal must take over as actionable
        // so the collapse recedes to glow, not to nothing.
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        let effect = m.handle(.reveal(.actionable))
        XCTAssertEqual(m.state, .dwelling(.actionable))
        XCTAssertEqual(effect, .startTimer(.actionable))
    }

    func testRevealWhilePausedHoldsPausedWithoutStartingTimer() {
        // If a reveal arrives while the user is hovering, honor the hover —
        // don't start a countdown under their cursor.
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        _ = m.handle(.hoverChanged(true))
        let effect = m.handle(.reveal(.actionable))
        XCTAssertEqual(m.state, .paused(.actionable))
        XCTAssertEqual(effect, .cancelTimer)
    }

    func testRevealUnderStationaryCursorStartsPaused() {
        // The cursor is already over the closed notch (ContentView sent
        // hoverChanged(true) while the machine was idle). A reveal that opens
        // under that stationary cursor must START PAUSED — never run a countdown
        // the user can't see to cancel by moving the mouse (WCAG 2.2.1).
        var m = NotchRevealMachine()
        XCTAssertEqual(m.handle(.hoverChanged(true)), .none)   // idle hover, remembered
        let effect = m.handle(.reveal(.actionable))
        XCTAssertEqual(m.state, .paused(.actionable))
        XCTAssertEqual(effect, .cancelTimer)
    }

    func testStationaryCursorThenMouseOutStartsTheTimer() {
        // After the paused-on-reveal case above, moving the cursor away starts
        // the dwell normally.
        var m = NotchRevealMachine()
        _ = m.handle(.hoverChanged(true))
        _ = m.handle(.reveal(.informational))
        let effect = m.handle(.hoverChanged(false))
        XCTAssertEqual(m.state, .dwelling(.informational))
        XCTAssertEqual(effect, .startTimer(.informational))
    }

    func testRedundantHoverSignalsAreNoOps() {
        var m = NotchRevealMachine()
        _ = m.handle(.reveal(.informational))
        // mouse-out while already dwelling (never hovered): nothing changes.
        XCTAssertEqual(m.handle(.hoverChanged(false)), .none)
        XCTAssertEqual(m.state, .dwelling(.informational))
        // hover-in twice: second is a no-op.
        _ = m.handle(.hoverChanged(true))
        XCTAssertEqual(m.handle(.hoverChanged(true)), .none)
        XCTAssertEqual(m.state, .paused(.informational))
    }
}
