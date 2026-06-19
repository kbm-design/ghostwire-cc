//
//  NotchRevealMachine.swift
//  Ghostwire
//
//  GW-264 / GW-227: the auto-reveal dwell-timer state machine. A reveal that the
//  user didn't trigger by hand (a permission auto-open, a voice-capture "here's
//  where it landed" pop) must behave like a notification: show for a few seconds,
//  then collapse on its own — unless the user engages it. This is the pure brain
//  of that behavior, kept free of timers / AppKit / Combine so the
//  start / pause-on-hover / restart / expire matrix is unit-testable.
//
//  Two reveal classes (the decided model):
//   • informational — track change, saved-to-Shelf, agent-finished,
//     waiting-for-input. Collapses to nothing on expiry.
//   • actionable — a pending approval / permission request. Collapses to the
//     passive glow/badge (toGlow:true); the pending request is NEVER dropped —
//     it stays in the Agents tab until the user acts. Collapsing the panel ≠
//     dismissing the request.
//
//  Hover (or any interaction) PAUSES the timer and mouse-out RESTARTS it, per
//  WCAG 2.2.1 (a time limit the user can pause). A thin @MainActor driver
//  (`NotchRevealController`) maps the emitted `Effect`s onto real timers and the
//  view model.
//

import Foundation

/// Why the notch auto-revealed — decides the collapse behavior.
enum NotchRevealClass: Equatable, Sendable {
    /// Track change, saved-to-Shelf, agent-finished, waiting-for-input. Collapse
    /// to nothing.
    case informational
    /// Pending approval / permission request. Collapse to the passive glow; the
    /// request stays pending in the Agents tab.
    case actionable
}

/// Pure dwell-timer state machine. Feed it `Event`s; it returns the `Effect`
/// the driver should perform and advances `state`. Deterministic and Equatable
/// so the whole reveal lifecycle is testable without a run loop.
struct NotchRevealMachine: Equatable {

    enum State: Equatable {
        /// No auto-reveal in flight (a manual/sticky open lives here too).
        case idle
        /// Counting down; will collapse when the timer fires.
        case dwelling(NotchRevealClass)
        /// Hovered/interacting — countdown suspended until mouse-out.
        case paused(NotchRevealClass)
    }

    enum Event: Equatable {
        /// A passive reveal fired (the notch auto-opened for this class).
        case reveal(NotchRevealClass)
        /// Hover/interaction began (true) or ended (false).
        case hoverChanged(Bool)
        /// The dwell timer elapsed.
        case timerFired
        /// The user took the notch over (tapped/clicked/acted) — it becomes a
        /// normal sticky open governed by the existing hover-close, not the dwell.
        case engaged
        /// The notch was closed by some other path; drop any pending dwell.
        case dismissed
    }

    enum Effect: Equatable {
        case startTimer(NotchRevealClass)
        case cancelTimer
        /// Collapse the notch. `toGlow` is true for actionable reveals — recede
        /// to the persistent passive glow/badge rather than vanish.
        case collapse(toGlow: Bool)
        case none
    }

    private(set) var state: State = .idle
    /// Whether the cursor is over the notch — tracked even while `idle` so a
    /// reveal that opens under a STATIONARY cursor (the user was already hovering
    /// the closed notch) starts paused instead of running an invisible countdown.
    private(set) var hovered: Bool = false

    /// Advance the machine and return the effect to perform.
    mutating func handle(_ event: Event) -> Effect {
        switch event {

        // Hover is tracked in every state. It only changes the timer when a
        // dwell is in flight: pause an active countdown / restart it on mouse-out.
        case .hoverChanged(let isHovering):
            hovered = isHovering
            switch state {
            case .dwelling(let c) where isHovering:
                state = .paused(c)
                return .cancelTimer
            case .paused(let c) where !isHovering:
                state = .dwelling(c)
                return .startTimer(c)
            default:
                return .none
            }

        // A reveal (including upgrading an in-flight dwell to a new class, e.g.
        // an approval arriving during an info reveal): if the cursor is already
        // over the notch, hold paused under it; otherwise start the countdown.
        case .reveal(let c):
            if hovered {
                state = .paused(c)
                return .cancelTimer
            }
            state = .dwelling(c)
            return .startTimer(c)

        // Expiry collapses — to glow for actionable, to nothing for info. Only a
        // live (non-paused) countdown may fire; a stale fire after a pause is
        // ignored so we never collapse out from under a hovering user.
        case .timerFired:
            guard case .dwelling(let c) = state else { return .none }
            state = .idle
            return .collapse(toGlow: c == .actionable)

        // User takeover ends the dwell; the cursor is still where it is.
        case .engaged:
            guard state != .idle else { return .none }
            state = .idle
            return .cancelTimer

        // An external close ends the dwell AND clears stale hover (the cursor
        // is no longer meaningfully "on" a now-closed notch).
        case .dismissed:
            hovered = false
            guard state != .idle else { return .none }
            state = .idle
            return .cancelTimer
        }
    }
}
