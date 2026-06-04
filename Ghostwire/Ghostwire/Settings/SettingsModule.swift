//
//  SettingsModule.swift
//  Ghostwire
//
//  Feature modules for the settings sidebar (GW-144, MacNotch's MODULES
//  IA / Seam's "toggle only what you need"). Core sections stay fixed up
//  top; each module below gets a sidebar toggle and one pane.
//
//  Every module except Media reuses its feature's existing master key, so
//  the sidebar toggle and the feature stay one source of truth. Media's
//  key only hides the settings pane — the player is the app's core.
//

import Defaults
import SwiftUI

struct SettingsModule: Identifiable {
    /// Sidebar selection value (matches the detail switch in SettingsView).
    let id: String
    let label: String
    let icon: String
    /// Master toggle. Off = feature off (except Media) + pane gated.
    let enabledKey: Defaults.Key<Bool>
    /// Footer copy for the gated (disabled) pane state.
    let disabledHint: String

    static let media = SettingsModule(
        id: "Media",
        label: "Media",
        icon: "play.laptopcomputer",
        enabledKey: .mediaModuleEnabled,
        disabledHint: "Hides the Media settings pane. Playback features stay on."
    )
    static let calendar = SettingsModule(
        id: "Calendar",
        label: "Calendar",
        icon: "calendar",
        enabledKey: .showCalendar,
        disabledHint: "Shows calendar events in the notch."
    )
    static let huds = SettingsModule(
        id: "HUD",
        label: "HUDs",
        icon: "dial.medium.fill",
        enabledKey: .hudReplacement,
        disabledHint: "Replaces the system volume, brightness and backlight HUDs."
    )
    static let battery = SettingsModule(
        id: "Battery",
        label: "Battery",
        icon: "battery.100.bolt",
        enabledKey: .showBatteryIndicator,
        disabledHint: "Shows the battery indicator in the notch."
    )
    static let shelf = SettingsModule(
        id: "Shelf",
        label: "Shelf",
        icon: "books.vertical",
        enabledKey: .shelf,
        disabledHint: "Hold files in the notch and share them quickly."
    )
    static let mirror = SettingsModule(
        id: "Mirror",
        label: "Mirror",
        icon: "web.camera",
        enabledKey: .showMirror,
        disabledHint: "Shows a camera mirror in the open notch."
    )

    static let all: [SettingsModule] = [media, calendar, huds, battery, shelf, mirror]
}

/// Wraps a module's settings pane: shows the pane when the module is on,
/// otherwise a single enable toggle with the module's hint.
struct ModuleGate<Content: View>: View {
    private let module: SettingsModule
    private let content: Content
    @Default private var enabled: Bool

    init(_ module: SettingsModule, @ViewBuilder content: () -> Content) {
        self.module = module
        self.content = content()
        _enabled = Default(module.enabledKey)
    }

    var body: some View {
        if enabled {
            content
        } else {
            Form {
                Section {
                    Toggle("Enable \(module.label)", isOn: $enabled)
                        .tint(.effectiveAccent)
                } footer: {
                    Text(module.disabledHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(module.label)
        }
    }
}

/// Compact sidebar switch for a module row.
struct ModuleSidebarToggle: View {
    private let module: SettingsModule
    @Default private var enabled: Bool

    init(_ module: SettingsModule) {
        self.module = module
        _enabled = Default(module.enabledKey)
    }

    var body: some View {
        Toggle("", isOn: $enabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(.effectiveAccent)
    }
}
