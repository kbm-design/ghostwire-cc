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
}
