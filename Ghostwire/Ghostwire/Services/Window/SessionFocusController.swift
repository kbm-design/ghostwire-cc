//
//  SessionFocusController.swift
//  Ghostwire
//
//  GW-162: "Go to Terminal" without the yabai hard-gate. The old path
//  (YabaiController.focusWindow) returned false before any multiplexer
//  logic when yabai was absent, so focus was unreachable on standard
//  setups - violating the repo's tiered-support principle.
//
//  Tiers: cmux focuses entirely through its own CLI (select-workspace +
//  focus-panel) plus app activation - yabai never needed. tmux gets pane
//  switch + terminal-app activation as the baseline; yabai adds precise
//  window-level focus only when installed.
//

import AppKit
import Foundation

/// How to focus a session's pane (pure decision, testable)
enum SessionFocusStrategy: Equatable, Sendable {
    case cmuxChain(workspace: String, surface: String)
    case tmuxYabai(tty: String)
    case tmuxBaseline(tty: String)
    case none
}

@MainActor
final class SessionFocusController {
    static let shared = SessionFocusController()

    private init() {}

    /// Pure strategy choice: cmux never needs yabai; tmux uses it only as
    /// an enhancement when available.
    nonisolated static func strategy(
        for resolution: MultiplexerTargetResolution,
        yabaiAvailable: Bool
    ) -> SessionFocusStrategy {
        switch resolution {
        case .cmux(let workspace, let surface):
            return .cmuxChain(workspace: workspace, surface: surface)
        case .tmuxTty(let tty):
            return yabaiAvailable ? .tmuxYabai(tty: tty) : .tmuxBaseline(tty: tty)
        case .unresolvable:
            return .none
        }
    }

    /// Focus the terminal pane for a session using its stored identity
    /// (hook-provided refs / tty - never screen content).
    @discardableResult
    func focus(session: SessionState) async -> Bool {
        let resolution = MultiplexerTargetResolver.resolve(session: session)
        let yabaiAvailable = await WindowFinder.shared.isYabaiAvailable()

        switch Self.strategy(for: resolution, yabaiAvailable: yabaiAvailable) {
        case .cmuxChain(let workspace, let surface):
            let switched = await TmuxController.shared.switchToPane(
                target: .cmux(workspace: workspace, surface: surface)
            )
            activateCmuxApp()
            return switched

        case .tmuxYabai(let tty):
            guard let target = await TmuxTargetFinder.shared.findTarget(forTty: tty) else { return false }
            _ = await TmuxController.shared.switchToPane(target: target)
            // yabai path focuses the exact terminal window hosting the session
            if let pid = session.pid {
                return await YabaiController.shared.focusWindow(forClaudePid: pid)
            }
            activateTerminalApp(forSessionPid: session.pid)
            return true

        case .tmuxBaseline(let tty):
            guard let target = await TmuxTargetFinder.shared.findTarget(forTty: tty) else { return false }
            let switched = await TmuxController.shared.switchToPane(target: target)
            if let pid = session.pid {
                _ = await TerminalActivator.activateAndVerify(forSessionPid: pid)
            }
            return switched

        case .none:
            // GW-266: a plain terminal (no mux) has no pane to switch, but we can
            // still bring its owning terminal app fully frontmost. The old code
            // returned false here and focused NOTHING — so "Go to terminal" was a
            // no-op on standard setups. Refuse only if there's no resolvable
            // terminal ancestor.
            guard let pid = session.pid else { return false }
            return await TerminalActivator.activateAndVerify(forSessionPid: pid) != nil
        }
    }

    // MARK: - App activation (baseline tier - no yabai)

    private func activateCmuxApp() {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.cmuxterm.app"
        ).first {
            // GW-266: raise all of cmux's windows over the current frontmost app.
            TerminalActivator.activate(app)
        }
    }

    private func activateTerminalApp(forSessionPid pid: Int?) {
        guard let pid else { return }
        Task { _ = await TerminalActivator.activateAndVerify(forSessionPid: pid) }
    }
}
