//
//  WindowSettingsView.swift
//  Ghostwire
//
//  Settings as it appears inside the unified Ghostwire window — the app's ONLY
//  settings surface since the standalone `SettingsView` / `SettingsWindowController`
//  were retired. Navigation lives in the window's sidebar (a Settings disclosure
//  group); this view is just the pane host.
//
//  Eight panes: the seven core ones plus a single "Modules" pane that folds in all
//  feature modules, each with its enable toggle. Every pane view is REUSED verbatim
//  from the old standalone settings — only the navigation chrome changed.
//

import Defaults
import Sparkle
import SwiftUI

// MARK: - Panes

/// Top-level (not nested in the view) so the shared `GhostwireWindowModel` can
/// address a pane — that's what lets the menu bar / notch / onboarding open the
/// window directly on Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, advanced, about, modules

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        case .about: return "About"
        case .modules: return "Modules"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "command"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        case .modules: return "square.grid.2x2"
        }
    }

    /// Id used by `SettingsSearchIndex` (the search index predates this enum and
    /// keys core panes by their label). `.modules` has no single entry — it
    /// matches when ANY module matches. Unused while the sidebar search is
    /// pulled; kept so re-wiring it is a view change, not an index rewrite.
    var searchID: String { label }
}

// MARK: - Root

struct WindowSettingsView: View {
    @ObservedObject private var nav = GhostwireWindowModel.shared

    var body: some View {
        VStack(spacing: 0) {
            WindowPaneHeader(title: nav.settingsPane.label) {
                paneAction
            }
            content
                // The reused panes are `Form`s with no style of their own; the old
                // standalone SettingsView forced `.grouped` (a bare macOS Form
                // defaults to the columns style, which right-aligns labels and
                // spreads them across the full width — the broken layout).
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.black)
        .tint(.effectiveAccent)
        // Accent changes are applied at build time by the reused panes, so
        // the tree has to be rebuilt to re-tint in place.
        .id(nav.accentRefresh)
    }

    // MARK: - Header action

    @ViewBuilder
    private var paneAction: some View {
        switch nav.settingsPane {
        case .about:
            if let updaterController = nav.updaterController {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch nav.settingsPane {
            case .general:    GeneralSettings()
            case .appearance: Appearance()
            case .shortcuts:  Shortcuts()
            case .advanced:   Advanced()
            case .about:
                if let updaterController = nav.updaterController {
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
        .animation(.easeOut(duration: 0.15), value: nav.settingsPane)
    }
}

// MARK: - Modules (all of them folded into one pane)

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
        // GW-261 added the Feed module but never mapped its pane here, and
        // GW-182's Activity module repeated the mistake — both shipped a
        // sidebar toggle over a blank pane. The default branch now asserts so
        // the next unmapped module is caught the first time it's opened.
        case "Feed":     FeedSettings()
        case "Activity": AmbientSettings()
        default:
            let _ = assertionFailure("Unmapped settings module: \(module.id)")
            EmptyView()
        }
    }
}


// MARK: - Shared pane header

/// One header shape for every full-window pane: title left, a single action slot
/// right. Panes used to publish their action with `.toolbar`, which macOS put in
/// the window's transparent titlebar next to the traffic lights — so one button
/// beside the close/minimise/zoom controls changed identity as you moved between
/// panes (Quit app / ＋ Add Server / Check for Updates…). The slot is a fixed
/// width and holds nothing on panes with no action, so the title never shifts.
struct WindowPaneHeader<Action: View>: View {
    static var actionSlotWidth: CGFloat { 120 }

    let title: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            action()
                .frame(minWidth: Self.actionSlotWidth, alignment: .trailing)
                .controlSize(.regular)
        }
        .frame(height: 56)
        .padding(.horizontal, 28)
    }
}

extension WindowPaneHeader where Action == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
