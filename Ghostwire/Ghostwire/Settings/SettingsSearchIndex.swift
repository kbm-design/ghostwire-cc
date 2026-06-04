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
                "lock screen", "recording",
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
            keywords: ["keyboard", "hotkey", "sneak peek"]
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
            keywords: ["version", "update", "github", "release"]
        ),
    ]

    /// Module panes (sidebar MODULES section order mirrors SettingsModule.all).
    static let modules: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "Media", label: "Media", icon: "play.laptopcomputer",
            keywords: [
                "music", "player", "lyrics", "sneak peek", "controller",
                "spotify", "apple music", "youtube", "playback",
            ]
        ),
        SettingsSearchEntry(
            id: "Calendar", label: "Calendar", icon: "calendar",
            keywords: ["events", "reminders", "all-day"]
        ),
        SettingsSearchEntry(
            id: "HUD", label: "HUDs", icon: "dial.medium.fill",
            keywords: ["volume", "brightness", "backlight", "replacement", "percentage"]
        ),
        SettingsSearchEntry(
            id: "Battery", label: "Battery", icon: "battery.100.bolt",
            keywords: ["charge", "power", "percentage", "low power"]
        ),
        SettingsSearchEntry(
            id: "Shelf", label: "Shelf", icon: "books.vertical",
            keywords: ["files", "drag", "drop", "quick share", "airdrop", "tray"]
        ),
        SettingsSearchEntry(
            id: "Mirror", label: "Mirror", icon: "web.camera",
            keywords: ["camera", "webcam", "face", "shape"]
        ),
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
