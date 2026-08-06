//
//  SettingsStateColors.swift
//  Ghostwire
//
//  GW-356 §2 `state/` axis, in Swift. GW-356 landed the spec but deliberately
//  shipped no tokens — GW-255 is the first consumer and adds them here, so
//  nothing ships unused and the values stay tweakable against a real screen.
//
//  WHY THIS EXISTS AT ALL. `TerminalColors` is dark-only: `dim`/`dimmer` and the
//  surface ladder are white-opacity values, so on a light window background they
//  composite to 1.00:1 — invisible. Settings is the one surface that follows
//  system light/dark, so it needs state colors that RESOLVE per appearance
//  rather than a second table the call site picks between.
//
//  Each token is ONE dynamic `NSColor`. Never branch on `colorScheme` at a call
//  site: that reads the environment, which is wrong inside an `NSHostingView`
//  that AppKit re-renders for a different appearance, and it puts the palette in
//  the view instead of in one place.
//
//  Ratios below are measured against `NSColor.windowBackgroundColor`
//  (#1E1E1E dark / #FFFFFF light), sRGB, WCAG 2.x. Dark arms are the existing
//  `terminal/` constants VERBATIM so a state means the same color in both
//  halves of the app. Re-measure before changing one; don't eyeball it.
//

import AppKit
import SwiftUI

/// The Settings counterpart to `TerminalColors`. Five meanings, one vocabulary.
///
/// `pending` and `inert` intentionally resolve to the system `.secondary` label
/// rather than a hue: "connecting" and "disconnected" are the absence of a
/// state, and giving them a color of their own makes every list look alarming.
enum SettingsStateColors {
    // MARK: - Text-safe arms (4.5:1)

    /// trusted · connected · installed · already set up. 7.37 dark / 4.51 light.
    static let ok = dynamic(dark: TerminalColors.green, light: hex(0x43844D))

    /// needs the user to act — not trusted, needs auth, re-trust, plain text.
    /// 9.26 dark / 4.50 light.
    static let attention = dynamic(dark: TerminalColors.amber, light: hex(0x9D6E00))

    /// failed — the thing did not work. 5.08 dark / 4.51 light.
    static let error = dynamic(dark: TerminalColors.red, light: hex(0xDA3A3A))

    /// neutral emphasis — schema, capability, link. 6.01 dark / 4.51 light.
    static let info = dynamic(dark: TerminalColors.blue, light: hex(0x4A75C9))

    /// connecting · importing · probing. Carried by motion, not hue.
    static let pending = Color.secondary

    /// disconnected · not detected · nothing configured yet.
    static let inert = Color.secondary

    // MARK: - Non-text rung (3:1)

    /// Dots, hairlines and badge strokes need 3:1, not 4.5:1 — at 6–8px the
    /// text-safe light arms read muddy. **Text always takes the arms above.**
    enum Glyph {
        static let ok = dynamic(dark: TerminalColors.green, light: hex(0x55A660))
        static let attention = dynamic(dark: TerminalColors.amber, light: hex(0xC58A00))
        static let error = dynamic(dark: TerminalColors.red, light: hex(0xFF4444))
        static let info = dynamic(dark: TerminalColors.blue, light: hex(0x5D92FC))
    }

    // MARK: - Plumbing

    /// One token = one `NSColor(name:)` that answers per appearance. The name is
    /// required for AppKit to cache it; it is not user-visible.
    private static func dynamic(dark: Color, light: Color) -> Color {
        let darkNS = NSColor(dark)
        let lightNS = NSColor(light)
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? darkNS : lightNS
            })
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1)
    }
}

// MARK: - Status presentation

/// Severity is the *meaning*; the color is looked up from it. Keeping these
/// separate is what lets a status be unit-tested — a test can assert
/// "needsTrust is attention and carries a remedy" without rendering anything.
///
/// `CmuxSocketStatusPresentation.Row` is the pattern this follows (§8.4).
enum SettingsStateSeverity: Equatable {
    case ok
    case attention
    case error
    case pending
    case inert

    /// For text and glyphs that sit next to text.
    var color: Color {
        switch self {
        case .ok: return SettingsStateColors.ok
        case .attention: return SettingsStateColors.attention
        case .error: return SettingsStateColors.error
        case .pending: return SettingsStateColors.pending
        case .inert: return SettingsStateColors.inert
        }
    }

    /// For an 8×8 dot or a hairline — the relaxed 3:1 rung.
    var glyphColor: Color {
        switch self {
        case .ok: return SettingsStateColors.Glyph.ok
        case .attention: return SettingsStateColors.Glyph.attention
        case .error: return SettingsStateColors.Glyph.error
        case .pending: return SettingsStateColors.pending
        case .inert: return SettingsStateColors.inert
        }
    }

    /// §8.4: attention and error may NEVER go wordless. ok and inert may, but
    /// only when an adjacent element already says it.
    var requiresCaption: Bool {
        self == .attention || self == .error
    }
}

/// The §8.2 state dot: 8×8 in Settings, not the notch's 6×6 — at grouped-`Form`
/// density next to 13pt text it disappears at 6.
///
/// The accessibility label is the CAPTION, never the color (§8.4). A dot
/// announced as "orange" tells a screen-reader user nothing they can act on.
struct SettingsStateDot: View {
    let severity: SettingsStateSeverity
    let caption: String

    var body: some View {
        Circle()
            .fill(severity.glyphColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel(caption)
    }
}
