//
//  WindowSettingsView.swift
//  Ghostwire
//
//  GW-223. Settings as it appears INSIDE the unified Ghostwire window — a black
//  surface with a horizontal tab bar instead of the standalone `SettingsView`'s
//  NavigationSplitView sidebar (which rendered a second, grey source-list beside
//  the window's own sidebar).
//
//  Eight tabs: the seven core panes plus a single "Modules" tab that folds in all
//  six feature modules (Media / Calendar / HUDs / Battery / Shelf / Mirror), each
//  with its enable toggle. Every pane view is REUSED verbatim from the standalone
//  settings — only the navigation chrome changes.
//
//  The standalone `SettingsView` (menubar / notch gear) is untouched.
//

import Defaults
import Sparkle
import SwiftUI

struct WindowSettingsView: View {
    let updaterController: SPUStandardUpdaterController?

    @State private var pane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general, agents, appearance, shortcuts, mcp, advanced, about, modules

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .agents: return "Agents"
            case .appearance: return "Appearance"
            case .shortcuts: return "Shortcuts"
            case .mcp: return "MCP"
            case .advanced: return "Advanced"
            case .about: return "About"
            case .modules: return "Modules"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .agents: return "sparkles"
            case .appearance: return "paintbrush"
            case .shortcuts: return "command"
            case .mcp: return "server.rack"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            case .modules: return "square.grid.2x2"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.white.opacity(0.08))
            content
                // The reused panes are `Form`s with no style of their own; the
                // standalone SettingsView forced `.grouped` (a bare macOS Form
                // defaults to the columns style, which right-aligns labels and
                // spreads them across the full width — the broken layout).
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.black)
        .tint(.effectiveAccent)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Pane.allCases) { p in
                    SettingsTabButton(
                        label: p.label,
                        systemImage: p.systemImage,
                        isSelected: pane == p
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { pane = p }
                    }
                }
            }
            // Sit closer to the sidebar divider; tighter left gap.
            .padding(.leading, 6)
            .padding(.trailing, 16)
        }
        // Clear the transparent titlebar row.
        .padding(.top, 30)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch pane {
            case .general:    GeneralSettings()
            case .agents:     AgentsSettings()
            case .appearance: Appearance()
            case .shortcuts:  Shortcuts()
            case .mcp:        MCPSettingsView()
            case .advanced:   Advanced()
            case .about:
                if let updaterController {
                    About(updaterController: updaterController)
                } else {
                    About(updaterController: SPUStandardUpdaterController(
                        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))
                }
            case .modules:    ModulesPane()
            }
        }
        // Push the reused Form-based panes toward the black canvas.
        .scrollContentBackground(.hidden)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: pane)
    }
}

// MARK: - Modules (all six folded into one tab)

private struct ModulesPane: View {
    private let modules = SettingsModule.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                    ModuleBlock(module: module)
                    if index < modules.count - 1 {
                        Divider().overlay(Color.white.opacity(0.06))
                            .padding(.vertical, 6)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// One module's header (icon + label + enable toggle) with its pane below when on.
private struct ModuleBlock: View {
    let module: SettingsModule
    @Default private var enabled: Bool

    init(module: SettingsModule) {
        self.module = module
        _enabled = Default(module.enabledKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: module.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(module.label)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                ModuleSidebarToggle(module)
            }

            if enabled {
                pane
                    .scrollContentBackground(.hidden)
            } else {
                Text(module.isAvailable() ? module.disabledHint
                                          : (module.unavailableHint ?? module.disabledHint))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var pane: some View {
        switch module.id {
        case "Media":    Media()
        case "Calendar": CalendarSettings()
        case "HUD":      HUD()
        case "Battery":  Charge()
        case "Shelf":    Shelf()
        case "Mirror":   MirrorSettings()
        // GW-261 added the Feed module but never mapped its pane here, so the
        // Sources UI was reachable only from the legacy settings window.
        case "Feed":     FeedSettings()
        default:         EmptyView()
        }
    }
}

// MARK: - Tab button

private struct SettingsTabButton: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
