//
//  SessionFocusStrategyTests.swift
//  GhostwireTests
//
//  GW-162: "Go to Terminal" was hard-gated on yabai (a SIP-disabled tiling
//  WM) before any multiplexer logic ran - with yabai absent the focus
//  buttons were hidden and the chat-bar button silently no-oped. Per the
//  repo's tiered-support principle, yabai is an optional enhancement:
//  cmux focuses entirely through its own CLI + app activation; tmux gets
//  pane switch + terminal-app activation, with yabai adding window-level
//  focus only when present.
//

import XCTest
@testable import Ghostwire

final class SessionFocusStrategyTests: XCTestCase {

    func testCmuxNeverUsesYabai() {
        let strategy = SessionFocusController.strategy(
            for: .cmux(workspace: "workspace:17", surface: "surface:35"),
            yabaiAvailable: true
        )
        XCTAssertEqual(strategy, .cmuxChain(workspace: "workspace:17", surface: "surface:35"))
    }

    func testTmuxPrefersYabaiWhenAvailable() {
        XCTAssertEqual(
            SessionFocusController.strategy(for: .tmuxTty("ttys003"), yabaiAvailable: true),
            .tmuxYabai(tty: "ttys003")
        )
    }

    func testTmuxFallsBackToBaselineWithoutYabai() {
        // the GW-162 gap: no yabai must still focus (pane switch + app activation)
        XCTAssertEqual(
            SessionFocusController.strategy(for: .tmuxTty("ttys003"), yabaiAvailable: false),
            .tmuxBaseline(tty: "ttys003")
        )
    }

    func testUnresolvableFocusesNothing() {
        XCTAssertEqual(
            SessionFocusController.strategy(for: .unresolvable(.notInMultiplexer), yabaiAvailable: true),
            .none
        )
    }
}
