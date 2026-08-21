//
//  GhostwireWindowModel.swift
//  Ghostwire
//
//  Navigation state for the unified Ghostwire window. Shared (not window-local
//  @State) because the window is now the app's ONLY settings surface: the
//  menu-bar item, the notch context menu and onboarding all need to open it on
//  a specific pane, which a private @State inside `GhostwireWindowView` can't
//  express.
//
//  Also holds the Sparkle updater the About pane needs. That reference used to
//  live on `SettingsWindowController`, which this change deletes.
//

import Sparkle
import SwiftUI

@MainActor
final class GhostwireWindowModel: ObservableObject {
    static let shared = GhostwireWindowModel()

    @Published var tab: GhostwireWindowTab = .shelf
    @Published var settingsPane: SettingsPane = .general
    /// Bumped when the accent color changes so the settings tree re-tints in
    /// place — `.tint` is resolved at build time by the reused Form panes.
    @Published var accentRefresh = UUID()

    /// Set once at launch by `GhostwireApp.init`.
    var updaterController: SPUStandardUpdaterController?

    private init() {}

    /// Point the window at Settings. Callers still have to show the window
    /// (`ShelfWindowController.shared.showWindow()`); this only sets where it lands.
    func showSettings(_ pane: SettingsPane = .general) {
        tab = .settings
        settingsPane = pane
    }
}
