//
//  FocusedFieldService.swift
//  Ghostwire
//
//  GW-229: decide where a finished voice transcript should land. If the user is
//  focused in an editable text field (a chat box, a doc, an agent terminal),
//  the transcript is pasted right there — true dictation. Otherwise the caller
//  falls back to clipboard + Shelf.
//
//  Both the focus probe and the paste rely on the Accessibility permission the
//  app already requests in onboarding. If it isn't granted, `isEditableField-
//  Focused()` returns false and we never paste — the safe default is to fall
//  back to clipboard + Shelf rather than risk pasting into the wrong place.
//

import AppKit
import ApplicationServices

enum FocusedFieldService {
    /// Whether the frontmost app's focused element is an editable text field.
    /// Conservative: any uncertainty (no permission, no focused element, role
    /// we don't recognize) returns false so we never paste into the wrong spot.
    static func isEditableFieldFocused() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else { return false }
        // CFTypeRef from the AX API is an AXUIElement.
        let element = focused as! AXUIElement

        // PRIMARY gate: a known editable text role.
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if let role = copyStringAttribute(element, kAXRoleAttribute), editableRoles.contains(role) {
            return true
        }

        // SECONDARY: an editable text element with a custom/unknown role (e.g.
        // some web editors). Require BOTH a settable value AND a selected-text
        // range — neither alone is sufficient:
        //   • settable value alone → sliders/steppers/other controls qualify
        //   • selected-text range alone → non-editable web areas in browsers
        //     expose one even when you can't type into them
        var settable: DarwinBoolean = false
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        var rangeRef: CFTypeRef?
        let hasTextRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        return valueSettable && hasTextRange
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Paste the current clipboard into the frontmost app's focused field by
    /// synthesizing ⌘V. The caller stages the transcript on the clipboard first.
    /// Reuses the shelf's paste path (the notch is a non-activating panel, so the
    /// user's app is still frontmost). Returns false if Accessibility is denied
    /// or the keystroke couldn't be posted.
    @MainActor
    static func paste() async -> Bool {
        await KeystrokePaster.pasteIntoPreviousApp()
    }
}
