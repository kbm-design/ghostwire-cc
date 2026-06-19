//
//  TerminalActivationTargetTests.swift
//  GhostwireTests
//
//  GW-266 / GW-212: "Go to terminal" must activate the TERMINAL app that owns the
//  agent — never the agent process itself (an agent pid isn't an app, so
//  activating it focuses nothing and the terminal stays behind whatever's
//  frontmost). The activation target is resolved by walking the process tree to
//  the terminal ancestor; this pins that resolution so the pid bug can't regress.
//

import XCTest
@testable import Ghostwire

final class TerminalActivationTargetTests: XCTestCase {

    private func node(_ pid: Int, ppid: Int, _ command: String) -> GhostwireProcessInfo {
        GhostwireProcessInfo(pid: pid, ppid: ppid, command: command, tty: nil)
    }

    /// agent → shell → terminal app. The target must be the terminal pid.
    func testResolvesTerminalAncestorNotAgentPid() {
        let tree: [Int: GhostwireProcessInfo] = [
            500: node(500, ppid: 400, "claude"),    // the agent process
            400: node(400, ppid: 300, "zsh"),       // login shell
            300: node(300, ppid: 1, "Ghostty"),     // owning terminal app
        ]

        let target = ProcessTreeBuilder.shared.findTerminalPid(forProcess: 500, tree: tree)

        XCTAssertEqual(target, 300, "must activate the terminal app pid, not the agent pid")
        XCTAssertNotEqual(target, 500, "activating the agent pid (GW-212 bug) focuses nothing")
    }

    /// No terminal in the ancestry → nil, so the caller refuses rather than
    /// activating the wrong process.
    func testReturnsNilWhenNoTerminalAncestor() {
        let tree: [Int: GhostwireProcessInfo] = [
            500: node(500, ppid: 400, "claude"),
            400: node(400, ppid: 1, "zsh"),
        ]

        XCTAssertNil(ProcessTreeBuilder.shared.findTerminalPid(forProcess: 500, tree: tree))
    }

    /// The session pid is itself the terminal (no agent child layer) — returns it.
    func testResolvesWhenSessionPidIsTheTerminal() {
        let tree: [Int: GhostwireProcessInfo] = [
            300: node(300, ppid: 1, "iTerm2"),
        ]

        XCTAssertEqual(ProcessTreeBuilder.shared.findTerminalPid(forProcess: 300, tree: tree), 300)
    }
}
