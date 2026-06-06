//
//  AgentTargetResolver.swift
//  Ghostwire
//
//  GW-164 (B): resolve the *active* agent session for send-to-agent.
//
//  This inverts the existing "is THIS session focused?" probe
//  (`TerminalVisibilityDetector.isSessionFocused`): rather than asking about
//  one session, we iterate the live sessions and ask which one the user is
//  looking at. Selection policy is a pure function so it is unit-tested
//  against sample session lists; the live focus probe (sysctl/CGWindowList)
//  is isolated in the actor method.
//
//  Policy:
//    - exactly one live session            -> that's the target (.single)
//    - a focused session among many        -> the focused one (.focused)
//    - several live, none focused          -> .candidates (UI picks)
//    - no live sessions                    -> .none
//
//  "Live" = a session that hasn't ended AND has a usable delivery path. The
//  path is TIERED (AGENTS.md): a multiplexer-addressable pane (cmux/tmux) OR
//  the baseline tier — a plain terminal we can focus + paste into, which only
//  needs a pid. Addressability therefore determines the injection TIER, not
//  eligibility: a single plain-terminal session must still resolve to a target
//  (the baseline environment the house rules require). A provisional/
//  transcript-only session with neither a pane nor a pid is never a target.
//

import Foundation

/// The outcome of resolving which agent session to send to.
enum AgentTarget: Equatable, Sendable {
    /// The only live session — no disambiguation needed.
    case single(sessionId: String)
    /// The focused session, chosen out of several live ones.
    case focused(sessionId: String)
    /// Several live sessions and none is focused — the UI shows a picker.
    case candidates(sessionIds: [String])
    /// Nothing addressable.
    case none

    /// The unambiguous target sessionId, if there is exactly one.
    var resolvedSessionId: String? {
        switch self {
        case .single(let id), .focused(let id):
            return id
        case .candidates, .none:
            return nil
        }
    }
}

/// How a live session's input will be reached. Carried from resolution so the
/// injection service doesn't re-derive it and risk an inconsistent choice.
enum InjectionTier: Equatable, Sendable {
    /// Multiplexer-addressable pane (cmux/tmux) — `ToolApprovalHandler.sendText`.
    case multiplexer
    /// Plain terminal — focus the owning terminal app, then paste (baseline).
    case baseline
}

/// A session that can actually receive an injection, with the tier it resolved
/// to. `liveSessions` produces these; selection works over their ids.
struct LiveSession: Equatable, Sendable {
    let session: SessionState
    let tier: InjectionTier
}

enum AgentTargetResolver {

    // MARK: - Pure selection seam (unit-tested)

    /// Choose the target from the live session ids and which one, if any, is
    /// focused. `liveSessionIds` order is preserved for candidates so the UI
    /// picker is stable.
    static func selectTarget(
        liveSessionIds: [String],
        focusedSessionId: String?
    ) -> AgentTarget {
        switch liveSessionIds.count {
        case 0:
            return .none
        case 1:
            return .single(sessionId: liveSessionIds[0])
        default:
            if let focused = focusedSessionId, liveSessionIds.contains(focused) {
                return .focused(sessionId: focused)
            }
            return .candidates(sessionIds: liveSessionIds)
        }
    }

    /// The injection tier for a session, or `nil` if it has no delivery path.
    /// Multiplexer-addressable panes take the mux tier; a plain terminal with a
    /// pid takes the baseline tier (focus + paste). No pane and no pid -> nil.
    static func injectionTier(for session: SessionState) -> InjectionTier? {
        if MultiplexerTargetResolver.resolve(session: session).isResolvable {
            return .multiplexer
        }
        // Baseline tier needs a pid to find + focus the owning terminal.
        return session.pid != nil ? .baseline : nil
    }

    /// Sessions that can actually receive an injection, paired with their tier.
    /// A session is live when it hasn't ended AND has a delivery path — a mux
    /// pane (enhancement) OR a focusable plain terminal (baseline, required).
    /// Order is preserved so the candidate picker is stable.
    static func liveSessions(from sessions: [SessionState]) -> [LiveSession] {
        sessions.compactMap { session in
            guard session.phase != .ended else { return nil }
            guard let tier = injectionTier(for: session) else { return nil }
            return LiveSession(session: session, tier: tier)
        }
    }

    // MARK: - Live resolution (focus probe isolated here)

    /// Resolve the active target over the current sessions, probing focus.
    /// `isFocused` defaults to the real terminal-visibility probe but is
    /// injectable for tests.
    static func resolveActiveTarget(
        from sessions: [SessionState],
        isFocused: (SessionState) async -> Bool = { session in
            guard let pid = session.pid else { return false }
            return await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
        }
    ) async -> AgentTarget {
        let live = liveSessions(from: sessions)
        guard live.count > 1 else {
            return selectTarget(liveSessionIds: live.map(\.session.sessionId), focusedSessionId: nil)
        }

        // Only probe focus when there's something to disambiguate.
        var focusedId: String?
        for candidate in live where await isFocused(candidate.session) {
            focusedId = candidate.session.sessionId
            break
        }
        return selectTarget(liveSessionIds: live.map(\.session.sessionId), focusedSessionId: focusedId)
    }
}
