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
    /// Neutral mark for unknown agent / presence-only indicators (e.g. the closed-notch terminal mark)
    static let neutral = Color.white.opacity(0.62)

    /// Tint for an agent identifier ("claude" | "codex" | …). Unknown/nil → neutral.
    static func tint(for agent: String?) -> Color {
        switch agent?.lowercased() {
        case "claude": return claude
        case "codex": return codex
        default: return neutral
        }
    }
}
