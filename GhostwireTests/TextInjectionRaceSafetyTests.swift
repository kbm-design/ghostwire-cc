//
//  TextInjectionRaceSafetyTests.swift
//  GhostwireTests
//
//  GW-320 (Interaction Model spec §5): the notch composer and the terminal are
//  two live channels into one agent. A free-text reply typed in the notch must
//  never be injected into a session that has since reached a permission gate —
//  the keystrokes would land in a menu and answer a question the user never saw.
//
//  The GW-318 spike measured this window directly: with the notch holding a
//  PermissionRequest, Claude Code still renders its own prompt in the terminal
//  ~6s in, so both channels really are live at once.
//

import XCTest
@testable import Ghostwire

final class TextInjectionRaceSafetyTests: XCTestCase {

    // MARK: - Blocked phases

    func testWaitingForApprovalBlocksInjection() {
        let phase = SessionPhase.waitingForApproval(PermissionContext(
            toolUseId: "toolu_gw320",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date()
        ))
        XCTAssertTrue(phase.blocksTextInjection,
                      "Injecting free text at a gate would type into the permission menu")
    }

    func testEndedBlocksInjection() {
        XCTAssertTrue(SessionPhase.ended.blocksTextInjection,
                      "There is nothing left to type into once the session has ended")
    }

    // MARK: - Safe phases

    func testWaitingForInputAllowsInjection() {
        XCTAssertFalse(SessionPhase.waitingForInput.blocksTextInjection,
                       "State D is precisely the moment a free-text reply is wanted")
    }

    func testProcessingAllowsInjection() {
        // Deliberate: queueing a message mid-turn is normal, supported agent
        // behaviour. Treating it as a race would break typing ahead.
        XCTAssertFalse(SessionPhase.processing.blocksTextInjection,
                       "Queueing a message while the agent works is not a race")
    }

    func testIdleAndCompactingAllowInjection() {
        XCTAssertFalse(SessionPhase.idle.blocksTextInjection)
        XCTAssertFalse(SessionPhase.compacting.blocksTextInjection)
    }

    // MARK: - The race itself

    func testGateReachedAfterComposingBlocksTheSend() {
        // Compose while the agent is waiting on us...
        let atCompose = SessionPhase.waitingForInput
        XCTAssertFalse(atCompose.blocksTextInjection)

        // ...but the agent starts a turn and hits a gate before the send lands.
        // This transition is legal in the state machine, which is why the send
        // path has to re-check rather than trust the phase it rendered with.
        let atSend = SessionPhase.waitingForApproval(PermissionContext(
            toolUseId: "toolu_gw320_race",
            toolName: "Write",
            toolInput: nil,
            receivedAt: Date()
        ))
        XCTAssertTrue(atCompose.canTransition(to: atSend),
                      "waitingForInput -> waitingForApproval is a real transition")
        XCTAssertTrue(atSend.blocksTextInjection,
                      "The re-check must catch the gate that appeared mid-send")
    }
}
