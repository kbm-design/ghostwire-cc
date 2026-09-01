//
//  SettingsSearchIndex.swift
//  Ghostwire
//
//  Settings sidebar search (GW-144, MacNotch pattern): maps a query to
//  the panes it matches via label + static keyword lists. Keywords name
//  the controls a pane holds, not its concepts — search is for "where
//  did that toggle go", not discovery.
//

import Foundation

struct SettingsSearchEntry: Identifiable {
    /// Sidebar selection value (matches the detail switch in SettingsView).
    let id: String
    let label: String
    let icon: String
    let keywords: [String]
}

enum SettingsSearchIndex {

    /// Core (non-module) panes in sidebar order.
    static let core: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "General", label: "General", icon: "gear",
            keywords: [
                "menu bar", "launch", "login", "display", "screen", "height",
                "notch", "hover", "haptics", "gesture", "tabs", "reorder",
                "lock screen", "recording", "voice", "dictation", "speech",
            ]
        ),
        SettingsSearchEntry(
            id: "Agents", label: "Agents", icon: "terminal",
            keywords: [
                "claude", "codex", "gemini", "hooks", "install", "uninstall",
                "socket", "usage", "sound", "notification", "approval",
                "trust", "cmux", "alerts", "history", "message", "prompt", "raw",
            ]
        ),
        SettingsSearchEntry(
            id: "Appearance", label: "Appearance", icon: "eye",
            keywords: [
                "accent", "color", "spectrogram", "visualizer", "tint",
                "blur", "slider", "settings icon",
            ]
        ),
        SettingsSearchEntry(
            id: "Shortcuts", label: "Shortcuts", icon: "keyboard",
            keywords: ["keyboard", "hotkey", "sneak peek", "clipboard", "voice", "capture", "dictation"]
        ),
        SettingsSearchEntry(
            id: "MCP", label: "MCP Servers", icon: "server.rack",
            keywords: [
                "mcp", "model context protocol", "data", "tools", "server",
                "connect", "allowlist", "stdio", "oauth",
            ]
        ),
        SettingsSearchEntry(
            id: "Advanced", label: "Advanced", icon: "gearshape.2",
            keywords: [
                "accent", "custom color", "title bar", "hover area",
                "lock screen", "screen recording",
            ]
        ),
        SettingsSearchEntry(
            id: "About", label: "About", icon: "info.circle",
            keywords: ["version", "update", "github"]
        ),
    ]

    /// Module panes, derived from SettingsModule.all so label/icon live in
    /// ONE place (review finding: verbatim duplication drifted two registries).
    static let modules: [SettingsSearchEntry] = SettingsModule.all.map { module in
        SettingsSearchEntry(
            id: module.id,
            label: module.label,
            icon: module.icon,
            keywords: moduleKeywords[module.id] ?? []
        )
    }

    private static let moduleKeywords: [String: [String]] = [
        "Media": [
            "music", "player", "lyrics", "sneak peek", "controller",
            "spotify", "apple music", "youtube", "playback",
        ],
        "Calendar": ["events", "reminders", "all-day"],
        "HUD": ["volume", "brightness", "backlight", "replacement", "percentage"],
        "Battery": ["charge", "power", "percentage", "low power"],
        "Shelf": [
            "files", "drag", "drop", "quick share", "airdrop", "tray", "clipboard", "history", "copy", "paste",
            // GW-166 credential protection lives in the Shelf pane's Clipboard section.
            "password", "secret", "token", "api key", "credential", "sensitive", "touch id", "encrypt",
        ],
        "Mirror": ["camera", "webcam", "face", "shape"],
        "Activity": [
            "activity", "context", "ambient", "capture", "frontmost",
            "retention", "denylist", "excluded apps", "privacy", "history",
        ],
        "Feed": [
            "feed", "cards", "sources", "crypto", "price", "bitcoin", "btc",
            "hyperliquid", "rss", "atom", "news", "releases", "dashboard",
        ],
    ]

    /// Pane ids matching a query (case-insensitive substring over label +
    /// keywords). Empty/whitespace query matches everything.
    static func matches(_ query: String) -> Set<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = core + modules
        guard !trimmed.isEmpty else { return Set(all.map(\.id)) }
        return Set(
            all.filter { entry in
                entry.label.lowercased().contains(trimmed)
                    || entry.keywords.contains { $0.contains(trimmed) }
            }.map(\.id)
        )
    }
}
