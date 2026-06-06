//
//  CmuxSocketStatusModel.swift
//  Ghostwire
//
//  GW-206: proactive surface for the cmux socket-access state classified by
//  CmuxAccessProbe (GW-162). The reactive half already lives in the chat input
//  bar; this is the Settings -> Agents row that tells the user WHY sending to
//  cmux is blocked and the exact remedy, before they hit a dead send.
//
//  This is a MULTIPLEXER-level concern, not per-agent: cmux addresses surfaces
//  for whatever agent runs inside them (Claude or Codex alike), so one row
//  covers both. The state -> row mapping (glyph / tint / text / remedy) is a
//  pure function so it can be unit-tested without socket I/O.
//

import Combine
import Foundation
import SwiftUI

/// Pure presentation mapping for a `CmuxSocketAccess` value. No I/O — fed the
/// probe result, returns what the row should draw. Tested in isolation.
enum CmuxSocketStatusPresentation {

    /// Visual severity, mapped to the same green / amber / gray vocabulary the
    /// hook-status rows use (glyph + tint, not labels).
    enum Severity: Equatable {
        case ok        // green — control works
        case action    // amber — user must do something
        case neutral   // gray  — informational, never alarming
    }

    struct Row: Equatable {
        var severity: Severity
        /// SF Symbol for the leading glyph.
        var glyph: String
        /// Short status word shown next to the glyph.
        var status: String
        /// One-line remedy / explanation, shown beneath. `nil` when there's
        /// nothing actionable to say (e.g. the happy path).
        var remedy: String?
    }

    /// Whether this state is worth showing a row at all. cmux is an optional,
    /// tiered enhancement — users who don't use it must never see an alarm, so
    /// "no cmux installed" renders nothing.
    static func isVisible(_ access: CmuxSocketAccess) -> Bool {
        access != .unavailable
    }

    static func glyph(_ severity: Severity) -> String {
        switch severity {
        case .ok:      return "checkmark.circle.fill"
        case .action:  return "exclamationmark.triangle.fill"
        case .neutral: return "minus.circle"
        }
    }

    /// Map a probe result to its row. `.unavailable` returns `nil` (see
    /// `isVisible`) — callers should not render a row for it.
    static func row(for access: CmuxSocketAccess) -> Row? {
        switch access {
        case .ok:
            return Row(
                severity: .ok,
                glyph: glyph(.ok),
                status: "Connected",
                remedy: nil
            )

        case let .closedByPolicy(_, needsRestart):
            if needsRestart {
                // Config already names an open mode; the running server just
                // hasn't applied it (socket mode is read at launch only).
                return Row(
                    severity: .action,
                    glyph: glyph(.action),
                    status: "Restart needed",
                    remedy: "Restart cmux to apply the automation mode."
                )
            }
            // Default cmuxOnly (or password) mode: cmux is actively rejecting
            // external apps. The Settings-UI toggle persists to defaults, but
            // ~/.config/cmux/cmux.json is authoritative — point users there.
            return Row(
                severity: .action,
                glyph: glyph(.action),
                status: "Blocked",
                remedy: "cmux is blocking external apps. Set Socket Control Mode to "
                      + "\"Automation\" in cmux (or in ~/.config/cmux/cmux.json, which "
                      + "is authoritative), then restart cmux."
            )

        case .notRunning:
            // Not an error — cmux is optional. Neutral, no remedy.
            return Row(
                severity: .neutral,
                glyph: glyph(.neutral),
                status: "Not running",
                remedy: nil
            )

        case .unavailable:
            // No cmux installed — render nothing (never alarm non-users).
            return nil
        }
    }

    /// Convenience: copyable remedy text for the row, if any.
    static func remedy(for access: CmuxSocketAccess) -> String? {
        row(for: access)?.remedy
    }
}

/// Observable wrapper that runs the (I/O-bound) probe off the main thread on
/// demand. No timers / polling — refreshed on tab `.onAppear` and a manual
/// refresh affordance, matching HookStatusModel's "re-read on appearance" model.
@MainActor
final class CmuxSocketStatusModel: ObservableObject {
    static let shared = CmuxSocketStatusModel()

    /// `nil` until the first probe completes (avoids a flash of a wrong state).
    @Published private(set) var access: CmuxSocketAccess?
    @Published private(set) var isRefreshing = false

    private init() {}

    /// Run the live probe. The probe does socket I/O + a `cmux ping` subprocess,
    /// so it runs on a background task; only the published result hops back to
    /// the main actor. Cheap enough to call on every tab open.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let result = await CmuxAccessProbe.probe()
            self.access = result
            self.isRefreshing = false
        }
    }
}
