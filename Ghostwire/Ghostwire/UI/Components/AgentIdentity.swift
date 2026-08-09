//
//  AgentIdentity.swift
//  Ghostwire
//
//  Single source of truth for per-agent identity color (GW-138).
//  Color encodes WHICH agent; motion/icon encodes state. Unknown → neutral.
//

import SwiftUI

enum AgentIdentity {
    /// Claude peach (#DA7756)
    static let claude = Color(red: 0xDA / 255.0, green: 0x77 / 255.0, blue: 0x56 / 255.0)
    /// Codex teal (0.04, 0.64, 0.50)
    static let codex = Color(red: 0.04, green: 0.64, blue: 0.50)
    /// Cursor violet (#A855F7) — confirmed; Cursor's own accent is a burnt
    /// orange that collides with Claude's peach, so violet keeps it distinct.
    static let cursor = Color(red: 0xA8 / 255.0, green: 0x55 / 255.0, blue: 0xF7 / 255.0)
    // Cluster tints (GW-175) — distinct placeholders; reconfirm each against the
    // vendor's accent when wiring its live test-drive.
    /// Copilot indigo (#6366F1)
    static let copilot = Color(red: 0x63 / 255.0, green: 0x66 / 255.0, blue: 0xF1 / 255.0)
    /// Factory droid red (#E5484D)
    static let factory = Color(red: 0xE5 / 255.0, green: 0x48 / 255.0, blue: 0x4D / 255.0)
    /// Qoder emerald (#10B981)
    static let qoder = Color(red: 0x10 / 255.0, green: 0xB9 / 255.0, blue: 0x81 / 255.0)
    /// CodeBuddy magenta (#E0457B)
    static let codebuddy = Color(red: 0xE0 / 255.0, green: 0x45 / 255.0, blue: 0x7B / 255.0)
    /// Gemini blue (#4285F4) — Google's own brand blue, the one hue still free.
    /// Closest neighbour is Copilot indigo (#6366F1); they read apart at the
    /// notch's dot size but reconfirm both when Copilot gets its live drive.
    static let gemini = Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0)
    /// Neutral mark for unknown agent / presence-only indicators (e.g. the closed-notch terminal mark)
    static let neutral = Color.white.opacity(0.62)

    /// Tint for an agent identifier ("claude" | "codex" | …). Unknown/nil → neutral.
    static func tint(for agent: String?) -> Color {
        switch agent?.lowercased() {
        case "claude": return claude
        case "codex": return codex
        case "cursor": return cursor
        case "copilot": return copilot
        case "factory": return factory
        case "qoder": return qoder
        case "codebuddy": return codebuddy
        case "gemini": return gemini
        default: return neutral
        }
    }
}
