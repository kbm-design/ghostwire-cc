//
//  Constants.swift
//  Ghostwire
//
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    // GW-210: open the notch on the Shelf tab + show clipboard history.
    // Unbound by default (the third recorder row in the Shortcuts settings
    // pane lets the user assign it).
    static let openClipboardHistory = Self("openClipboardHistory")
    // GW-229: toggle voice capture (record → transcript → send to agent + Shelf).
    // Default ⌃⇧Space (avoids ⌥Space/Raycast and Fn/Wispr); reassignable in the
    // Shortcuts settings pane. Toggle for v1; Fn-hold push-to-talk is a follow-up
    // (needs a custom event tap the KeyboardShortcuts library can't provide).
    static let toggleVoiceCapture = Self("toggleVoiceCapture", default: .init(.space, modifiers: [.control, .shift]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))

    // GW-286: open the notch directly on a given tab. All unbound by default
    // (the user assigns them in the Shortcuts settings pane), matching the
    // openClipboardHistory precedent. Each routes through the same per-display
    // viewModel.open() path and respects GW-224's default-open-tab rules.
    static let openNotchAgents = Self("openNotchAgents")
    static let openNotchShelf = Self("openNotchShelf")
    static let openNotchDashboard = Self("openNotchDashboard")

    // GW-286: jump to (open + focus) the next pending approval. Navigation
    // ONLY — it never writes a verdict, so it's safe as a global hotkey.
    // Unbound by default.
    static let jumpToNextPendingApproval = Self("jumpToNextPendingApproval")

    // GW-267: act on the approval you're LOOKING AT — global keys that only
    // fire when the notch is open, on the Agents tab, drilled into a chat (one
    // request in front of you). Approve/Deny additionally require that session
    // to still have a pending approval; otherwise every one of these is a
    // no-op, so a stray press while you're not looking at a request does
    // nothing. All unbound by default. (No lock-screen vector — app hotkeys
    // don't fire while the Mac is locked.)
    static let approveFocusedApproval = Self("approveFocusedApproval")
    static let denyFocusedApproval = Self("denyFocusedApproval")
    static let openTerminalForFocusedSession = Self("openTerminalForFocusedSession")
}
