//
//  ContextStreakFolder.swift
//  Ghostwire
//
//  GW-172 — the honesty rules of the ambient spine, as pure functions so they
//  can be exercised without a live workspace (ContextStreakTests):
//
//   • Capture filter — empty / lock-screen / denylisted bundle IDs never
//     produce activity (applied at capture AND defensively on store load).
//   • Extend-don't-append — a matching fingerprint extends the trailing streak
//     in place instead of appending a duplicate event.
//   • Max-gap rule — a matching fingerprint only extends if the gap since its
//     last sample is small; a big gap (a lock, a sleep) starts a FRESH streak,
//     so an absent hour never silently extends whatever was frontmost before it.
//

import Foundation

enum ContextStreak {

    /// Lock-screen / auth surfaces that must never be recorded as activity —
    /// `loginwindow` and kin. Filtered at capture and on load (architecture §3).
    static let excludedBundleIDs: Set<String> = [
        "com.apple.loginwindow",            // the lock / login screen
        "com.apple.SecurityAgent",          // the unlock / auth prompt
        "com.apple.ScreenSaver.Engine",     // screensaver foreground
    ]

    /// Whether a frontmost app should be recorded. False for empty IDs, the
    /// lock-screen kin, and anything on the user's denylist.
    static func shouldCapture(bundleID: String, denylist: Set<String>) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if excludedBundleIDs.contains(bundleID) { return false }
        if denylist.contains(bundleID) { return false }
        return true
    }

    /// Fold a snapshot into the streak list. Extends the trailing streak when it
    /// shares the snapshot's fingerprint and the gap since its last sample is
    /// within `maxGap`; otherwise starts a fresh streak. Pure.
    ///
    /// - Note: callers filter the snapshot through `shouldCapture` first; this
    ///   function trusts the snapshot is recordable.
    static func folding(
        _ events: [ContextEvent],
        with snapshot: ContextSnapshot,
        maxGap: TimeInterval,
        newID: () -> UUID = UUID.init
    ) -> [ContextEvent] {
        var result = events

        // A matching fingerprint extends only when the gap since the trailing
        // streak's last sample is small AND time hasn't run backwards. The same
        // "within gap" test decides whether a *different* app's switch can be
        // attributed to the departing streak (below).
        let last = result.last
        let withinGap: Bool = {
            guard let last else { return false }
            let gap = snapshot.capturedAt.timeIntervalSince(last.end)
            return gap >= 0 && gap <= maxGap
        }()

        if let last, last.bundleID == snapshot.bundleID, withinGap {
            // Same context, small gap → extend in place (refresh the idle edge).
            result[result.count - 1] = last.extending(
                to: snapshot.capturedAt, idleAtEnd: snapshot.idleSeconds
            )
            return result
        }

        // Different context, or the gap is too large to honestly bridge. When the
        // gap IS small, close out the departing streak up to the switch moment so
        // a short visit isn't recorded as ~zero seconds and a switch doesn't drop
        // up to one backstop interval of dwell. Keep its existing idle edge — the
        // switch is itself an input event, so a fresh idle reading would be ~0 and
        // would erase any idle the departing app had actually accrued.
        if let last, withinGap {
            result[result.count - 1] = last.extending(
                to: snapshot.capturedAt, idleAtEnd: last.idleAtEnd
            )
        }

        result.append(ContextEvent(
            id: newID(),
            bundleID: snapshot.bundleID,
            appName: snapshot.appName,
            start: snapshot.capturedAt,
            end: snapshot.capturedAt,
            idleAtEnd: snapshot.idleSeconds
        ))
        return result
    }
}
