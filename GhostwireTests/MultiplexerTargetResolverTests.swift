//
//  MultiplexerTargetResolverTests.swift
//  GhostwireTests
//
//  GW-162: messaging/focus availability must reflect ACTUAL target
//  resolution, not process-tree flags. The old gate (isInMultiplexer &&
//  tty != nil) phantom-enabled the chat input for cmux sessions with no
//  stored refs, then dropped the send silently via a screen-scraping
//  fallback (first pane whose visible text contains the project folder
//  name - wrong-pane roulette with parallel worktrees).
//
//  Policy: hook-provided cmux refs > tmux tty match > unresolvable(why).
//  No screen-content fallback.
//

import XCTest
@testable import Ghostwire

final class MultiplexerTargetResolverTests: XCTestCase {

    func testCmuxRefsResolveDirectly() {
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: false, isInCmux: true,
            cmuxWorkspaceRef: "workspace:17", cmuxSurfaceRef: "surface:35",
            tty: "ttys011"
        )
        XCTAssertEqual(resolution, .cmux(workspace: "workspace:17", surface: "surface:35"))
    }

    func testCmuxRefsBeatTmuxTtyWhenBothPresent() {
        // a session inside cmux also has a tty; refs are the precise handle
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: true, isInCmux: true,
            cmuxWorkspaceRef: "workspace:2", cmuxSurfaceRef: "surface:4",
            tty: "ttys003"
        )
        XCTAssertEqual(resolution, .cmux(workspace: "workspace:2", surface: "surface:4"))
    }

    func testTmuxResolvesByTty() {
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: true, isInCmux: false,
            cmuxWorkspaceRef: nil, cmuxSurfaceRef: nil,
            tty: "ttys003"
        )
        XCTAssertEqual(resolution, .tmuxTty("ttys003"))
    }

    func testCmuxWithoutRefsIsUnresolvable() {
        // the phantom-enable case: in cmux per the process tree, but the
        // hook never delivered refs -> must NOT enable input, must say why
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: false, isInCmux: true,
            cmuxWorkspaceRef: nil, cmuxSurfaceRef: nil,
            tty: "ttys011"
        )
        XCTAssertEqual(resolution, .unresolvable(.cmuxRefsMissing))
    }

    func testCmuxWithPartialRefsIsUnresolvable() {
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: false, isInCmux: true,
            cmuxWorkspaceRef: "workspace:17", cmuxSurfaceRef: nil,
            tty: nil
        )
        XCTAssertEqual(resolution, .unresolvable(.cmuxRefsMissing))
    }

    func testCmuxWithoutRefsFallsBackToTmuxTtyIfAlsoInTmux() {
        // tmux-inside-cmux edge: refs missing but a tmux pane tty exists
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: true, isInCmux: true,
            cmuxWorkspaceRef: nil, cmuxSurfaceRef: nil,
            tty: "ttys007"
        )
        XCTAssertEqual(resolution, .tmuxTty("ttys007"))
    }

    func testTmuxWithoutTtyIsUnresolvable() {
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: true, isInCmux: false,
            cmuxWorkspaceRef: nil, cmuxSurfaceRef: nil,
            tty: nil
        )
        XCTAssertEqual(resolution, .unresolvable(.ttyMissing))
    }

    func testPlainTerminalIsUnresolvable() {
        let resolution = MultiplexerTargetResolver.resolve(
            isInTmux: false, isInCmux: false,
            cmuxWorkspaceRef: nil, cmuxSurfaceRef: nil,
            tty: "ttys001"
        )
        XCTAssertEqual(resolution, .unresolvable(.notInMultiplexer))
    }

    func testResolvableMirrorsResolution() {
        XCTAssertTrue(MultiplexerTargetResolution.cmux(workspace: "w", surface: "s").isResolvable)
        XCTAssertTrue(MultiplexerTargetResolution.tmuxTty("ttys001").isResolvable)
        XCTAssertFalse(MultiplexerTargetResolution.unresolvable(.notInMultiplexer).isResolvable)
    }
}
