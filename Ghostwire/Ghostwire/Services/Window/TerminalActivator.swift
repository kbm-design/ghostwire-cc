//
//  TerminalActivator.swift
//  Ghostwire
//
//  GW-266 / GW-212: bring an agent's owning TERMINAL app fully frontmost. The
//  single source of truth for "activate the terminal," shared by the
//  "Go to terminal" button (SessionFocusController) and send-to-agent paste
//  (AgentInjectionService), so the fix can't drift between them.
//
//  Two bugs this consolidates:
//   • The activation used a bare `app.activate()` (no options), which only
//     soft-activated — the terminal came up "second-most," behind whatever was
//     frontmost (Chrome / Claude Desktop). We pass `.activateAllWindows` to raise
//     every window of the app over the current frontmost.
//   • The target was resolved by walking the process tree to the terminal
//     ancestor — never the agent pid (an agent process isn't an app, so
//     activating it focuses nothing). See ProcessTreeBuilder.findTerminalPid.
//

import AppKit
import Foundation

@MainActor
enum TerminalActivator {

    /// Bring an already-resolved app fully frontmost — all its windows, over the
    /// current frontmost app. The `.activateAllWindows` option is the GW-266 fix.
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
    }

    /// Resolve the terminal app that owns `sessionPid`, bring it fully frontmost,
    /// and VERIFY it actually became frontmost (activation is async). Returns the
    /// terminal's bundle id on success — the precondition a safe paste needs — or
    /// nil if there's no terminal ancestor or it never came to front (caller
    /// should then refuse rather than act on the wrong app).
    @discardableResult
    static func activateAndVerify(forSessionPid sessionPid: Int) async -> String? {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: sessionPid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)),
              let bundleId = app.bundleIdentifier else {
            return nil
        }

        activate(app)

        // Poll briefly for the activation to take — frontmost updates async.
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                return bundleId
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
