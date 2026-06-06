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
//  "Live" = a session we can actually address (resolvable pane per
//  `MultiplexerTargetResolver`). A provisional/transcript-only session with
//  no pane is never an injection target.
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

enum AgentTargetResolver {

    // MARK: - Pure selection seam (unit-tested)

    /// Choose the target from the live (addressable) session ids and which one,
    /// if any, is focused. `liveSessionIds` order is preserved for candidates so
    /// the UI picker is stable.
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

    /// A session is a candidate target only if its pane is actually addressable.
    /// Mirrors the chat-input gate (GW-162) — no resolvable pane, no target.
    static func liveSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.filter { MultiplexerTargetResolver.resolve(session: $0).isResolvable }
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
            return selectTarget(liveSessionIds: live.map(\.sessionId), focusedSessionId: nil)
        }

        // Only probe focus when there's something to disambiguate.
        var focusedId: String?
        for session in live where await isFocused(session) {
            focusedId = session.sessionId
            break
        }
        return selectTarget(liveSessionIds: live.map(\.sessionId), focusedSessionId: focusedId)
    }
}
