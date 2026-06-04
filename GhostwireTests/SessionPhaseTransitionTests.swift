//
//  SessionPhaseTransitionTests.swift
//  GhostwireTests
//
//  GW-171 item 2: a Stop event (Claude finished its turn -> green "your turn")
//  arriving while a session is idle was silently ignored because
//  SessionPhase.canTransition didn't allow idle -> waitingForInput,
//  leaving the session stuck grey.
//

import XCTest
@testable import Ghostwire

final class SessionPhaseTransitionTests: XCTestCase {

    func testIdleCanTransitionToWaitingForInput() {
        XCTAssertTrue(SessionPhase.idle.canTransition(to: .waitingForInput),
                      "Stop on an idle session must be able to show 'your turn'")
    }

    func testStopOnIdleSessionShowsWaitingForInput() async {
        // Real-world case: the app launches (or a session registers) mid-turn,
        // so the first event it sees for the session is the Stop.
        let sessionId = "gw171-stop-on-idle-\(UUID().uuidString)"

        await SessionStore.shared.process(.hookReceived(HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/gw171-tests",
            event: "Stop",
            status: "waiting_for_input",
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )))

        let phase = await SessionStore.shared.session(for: sessionId)?.phase
        XCTAssertEqual(phase, .waitingForInput,
                       "Stop on an idle session was ignored - session stuck grey")
    }
}
