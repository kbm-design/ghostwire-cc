//
//  CmuxFocusCommandsTests.swift
//  GhostwireTests
//
//  GW-162: cmux surface focus used `tab-action --action select`, which is
//  not a valid tab-action (contract: rename/close-*/reload/duplicate/pin/
//  unpin/mark-unread - no "select"), so cmux pane focus never worked. The
//  correct verb is `focus-panel --panel <surface>` ("surface focus" per the
//  CLI contract; accepts surface refs - verified live 2026-06-04).
//

import XCTest
@testable import Ghostwire

final class CmuxFocusCommandsTests: XCTestCase {

    func testFocusSurfaceSelectsWorkspaceThenFocusesPanel() {
        let commands = TmuxController.cmuxFocusCommands(workspace: "workspace:17", surface: "surface:35")
        XCTAssertEqual(commands, [
            ["select-workspace", "--workspace", "workspace:17"],
            ["focus-panel", "--panel", "surface:35", "--workspace", "workspace:17"],
        ])
    }

    func testNoTabActionSelectAnywhere() {
        // regression guard for the invalid verb
        let commands = TmuxController.cmuxFocusCommands(workspace: "w", surface: "s")
        XCTAssertFalse(commands.contains { $0.contains("tab-action") })
    }

    func testPasswordPrependedToEveryFocusCommand() {
        // Codex review P2: passworded sockets worked for send but not focus
        let commands = TmuxController.cmuxFocusCommands(workspace: "w", surface: "s", password: "hunter2")
        XCTAssertEqual(commands, [
            ["--password", "hunter2", "select-workspace", "--workspace", "w"],
            ["--password", "hunter2", "focus-panel", "--panel", "s", "--workspace", "w"],
        ])
    }

    func testNoPasswordFlagWhenSocketIsOpen() {
        let commands = TmuxController.cmuxFocusCommands(workspace: "w", surface: "s", password: nil)
        XCTAssertFalse(commands.contains { $0.contains("--password") })
    }
}
