//
//  NotchRevealControllerTests.swift
//  GhostwireTests
//
//  GW-264: the driver wiring around NotchRevealMachine — that the real dwell
//  timer actually collapses an auto-reveal, that hover pauses it, and that
//  engaging/dismissing cancels it. Uses the controller's injected seams (a spy
//  close + tiny dwell) so no window or run loop is needed.
//

import XCTest
@testable import Ghostwire

@MainActor
final class NotchRevealControllerTests: XCTestCase {

    private var controller: NotchRevealController!
    private var savedClose: ((GhostwireViewModel?) -> Void)!
    private var savedDwell: ((NotchRevealClass) -> Double)!
    private var closeCount = 0
    private var lastClosedTarget: GhostwireViewModel?

    override func setUp() async throws {
        controller = NotchRevealController.shared
        savedClose = controller.closeNotch
        savedDwell = controller.dwellSeconds
        closeCount = 0
        controller.closeNotch = { [weak self] target in
            self?.closeCount += 1
            self?.lastClosedTarget = target
        }
        controller.dwellSeconds = { _ in 0.05 }   // 50ms dwell for fast tests
        // Reset any in-flight dwell from a prior test/app state.
        controller.dismissed()
        closeCount = 0
    }

    override func tearDown() async throws {
        controller.dismissed()
        controller.closeNotch = savedClose
        controller.dwellSeconds = savedDwell
    }

    /// Poll for the collapse rather than a fixed sleep — removes lower-bound
    /// timing flakiness when the suite runs under CPU contention.
    private func waitForClose(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while closeCount == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInformationalRevealAutoCollapsesAfterDwell() async throws {
        controller.reveal(.informational)
        await waitForClose()
        XCTAssertEqual(closeCount, 1, "the info reveal should auto-collapse once after its dwell")
    }

    func testHoverHoldsTheRevealOpen() async throws {
        controller.reveal(.actionable)
        controller.hoverChanged(true)            // pause the countdown
        // Well past the 50ms dwell: if hover didn't hold it, it would have closed.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(closeCount, 0, "hovering must hold the reveal open past the dwell")

        controller.hoverChanged(false)           // mouse-out restarts it
        await waitForClose()
        XCTAssertEqual(closeCount, 1, "mouse-out restarts the dwell and it then collapses")
    }

    func testCollapseClosesTheRevealedTargetViewModel() async throws {
        // GW-264 multi-display: the dwell must collapse the notch that was
        // actually revealed, not whichever VM the bridge happens to hold.
        let target = GhostwireViewModel(screenUUID: "test-screen-uuid")
        controller.reveal(.informational, target: target)
        await waitForClose()
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(lastClosedTarget === target, "the dwell must close the revealed view model")
    }

    func testEngagingCancelsAutoCollapse() async throws {
        controller.reveal(.informational)
        controller.engaged()                     // user took it over
        // Past the dwell: a cancelled timer must never fire.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(closeCount, 0, "a user-engaged notch must never auto-collapse")
    }
}
