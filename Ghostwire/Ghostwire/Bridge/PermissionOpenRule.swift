//
//  PermissionOpenRule.swift
//  Ghostwire
//
//  GW-209: pure gate decision for a new pending permission. Splits the two
//  effects the bridge raises — the passive ALERT (glow + haptic + record) and
//  the notch OPEN — so they can diverge per mode without entangling the async
//  visibility probe with the publish flow. Kept free of AppKit/Combine so the
//  3 modes × pane-focused × notch-closed matrix is unit-testable.
//

import Foundation

enum PermissionOpenRule {
    /// The two independent effects a new pending permission can raise.
    struct Decision: Equatable {
        /// Glow + haptic + AlertHistoryStore.record.
        let alert: Bool
        /// Auto-open the notch (always also requires `notchClosed`).
        let open: Bool
    }

    /// Decide what a fresh pending permission should trigger.
    ///
    /// - Parameters:
    ///   - mode: the user's `permissionAutoOpenMode` preference.
    ///   - notchClosed: precondition for the OPEN (never open over an open notch).
    ///   - paneFocused: is the triggering session's own pane focused/visible?
    ///     (Smart's per-session visibility signal; ignored by Always.)
    static func decide(
        mode: PermissionAutoOpenMode,
        notchClosed: Bool,
        paneFocused: Bool
    ) -> Decision {
        // The passive alert follows the Smart visibility rule for every mode:
        // raise it only when the triggering pane isn't already in front of you.
        // (Always still suppresses it when you're staring at that pane — there's
        // nothing to alert; the open is what Always forces.)
        let alert = !paneFocused

        let open: Bool
        switch mode {
        case .smart:
            // Open only when the triggering pane isn't focused.
            open = notchClosed && !paneFocused
        case .always:
            // Open on every new permission, regardless of visibility.
            open = notchClosed
        case .never:
            // Never auto-open.
            open = false
        }

        return Decision(alert: alert, open: open)
    }
}
