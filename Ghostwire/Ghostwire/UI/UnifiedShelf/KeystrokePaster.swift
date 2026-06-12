//
//  KeystrokePaster.swift
//  Ghostwire
//
//  GW-218. The card "Paste into current field" action: synthesize ⌘V into the
//  app the user was using. Same CGEvent technique as
//  AgentInjectionService.pasteIntoFrontmost, but it targets the previously-
//  frontmost app rather than a resolved terminal.
//
//  The notch is a non-activating panel, so the user's app stays the *active*
//  app (NSWorkspace.frontmostApplication keeps pointing at it). Clicking a hover
//  button can still make our panel the key window, so we re-activate that app
//  before posting ⌘V to make sure the keystroke lands in its focused field.
//
//  Requires Accessibility / Input-Monitoring permission — `AXIsProcessTrusted()`
//  gates it, and we return false (caller shows a quiet failure glyph) when it's
//  not granted or the event can't be posted.
//

import AppKit
import ApplicationServices
import CoreGraphics

enum KeystrokePaster {
    /// Returns false when Accessibility isn't granted or the keystroke couldn't
    /// be posted; true once ⌘V has been dispatched.
    @MainActor
    static func pasteIntoPreviousApp() async -> Bool {
        guard AXIsProcessTrusted() else { return false }

        // We're non-activating, so this is still the user's real app.
        let previous = NSWorkspace.shared.frontmostApplication
        let isSelf = previous?.bundleIdentifier == Bundle.main.bundleIdentifier
        if let previous, !isSelf {
            previous.activate()
            try? await Task.sleep(for: .milliseconds(70))
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
