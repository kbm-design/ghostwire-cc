//
//  IdleStateRule.swift
//  Ghostwire
//
//  GW-199: idle home state. Both agents inactive 5h+ AND no live session →
//  idle: the notch opens on the Home tab, the closed-notch agent mark hides,
//  and the meter row dims. Pure rule - the SwiftUI wiring stays thin.
//

import Foundation

enum IdleStateRule {
    /// Trailing window in which any agent activity counts as "active"
    static let activityWindow: TimeInterval = 5 * 3600

    /// `signalsReady`: pass false until both services' first activity scans
    /// complete - a nil date before the scan means "unknown", not "stale",
    /// and must not produce a cold-start false idle (review fix).
    static func isIdle(
        now: Date,
        claudeLastActivity: Date?,
        codexLastActivity: Date?,
        hasLiveSessions: Bool,
        signalsReady: Bool = true
    ) -> Bool {
        guard signalsReady else { return false }
        if hasLiveSessions { return false }

        // Any agent active within the window keeps the whole surface awake;
        // exactly-at-threshold counts as elapsed (boundary is idle)
        func isFresh(_ date: Date?) -> Bool {
            guard let date else { return false }
            return now.timeIntervalSince(date) < activityWindow
        }

        return !isFresh(claudeLastActivity) && !isFresh(codexLastActivity)
    }
}
