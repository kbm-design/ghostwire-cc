//
//  MultiplexerTargetResolver.swift
//  Ghostwire
//
//  GW-162: the single policy for "can we address this session's pane".
//  Messaging/focus availability keys off this, not process-tree flags -
//  the old gate phantom-enabled input for cmux sessions without stored
//  refs and then dropped sends silently through a screen-scraping
//  fallback (first pane whose visible text mentioned the project name).
//
//  Policy: hook-provided cmux refs > tmux tty match > unresolvable(why).
//  No screen-content matching - with parallel worktrees in one repo it
//  picks the wrong pane.
//

import Foundation

/// Why a session's pane can't be addressed (drives the UI explanation)
enum MultiplexerTargetGap: Equatable, Sendable {
    /// In cmux per the process tree, but the hook never delivered
    /// workspace/surface refs
    case cmuxRefsMissing
    /// In tmux but no pane tty recorded
    case ttyMissing
    /// Plain terminal - no multiplexer to address
    case notInMultiplexer
}

/// How to reach the session's pane
enum MultiplexerTargetResolution: Equatable, Sendable {
    /// Exact cmux refs captured by the hook from the agent's own pane env
    case cmux(workspace: String, surface: String)
    /// Match the tmux pane whose #{pane_tty} equals this tty
    case tmuxTty(String)
    case unresolvable(MultiplexerTargetGap)

    var isResolvable: Bool {
        if case .unresolvable = self { return false }
        return true
    }
}

enum MultiplexerTargetResolver {

    static func resolve(
        isInTmux: Bool,
        isInCmux: Bool,
        cmuxWorkspaceRef: String?,
        cmuxSurfaceRef: String?,
        tty: String?
    ) -> MultiplexerTargetResolution {
        // cmux refs are the precise handle - prefer them whenever complete
        if isInCmux, let ws = cmuxWorkspaceRef, let surf = cmuxSurfaceRef {
            return .cmux(workspace: ws, surface: surf)
        }
        if isInTmux, let tty {
            return .tmuxTty(tty)
        }
        if isInCmux { return .unresolvable(.cmuxRefsMissing) }
        if isInTmux { return .unresolvable(.ttyMissing) }
        return .unresolvable(.notInMultiplexer)
    }

    /// Convenience over a session's stored fields
    static func resolve(session: SessionState) -> MultiplexerTargetResolution {
        resolve(
            isInTmux: session.isInTmux,
            isInCmux: session.isInCmux,
            cmuxWorkspaceRef: session.cmuxWorkspaceRef,
            cmuxSurfaceRef: session.cmuxSurfaceRef,
            tty: session.tty
        )
    }
}
