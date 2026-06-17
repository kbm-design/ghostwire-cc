//
//  GhostwireWindowView.swift
//  Ghostwire
//
//  GW-223. Root of the detached Ghostwire window: a left source-list sidebar
//  (Home / Agents / Shelf) over a black content area that hosts the SAME tab
//  views the notch uses — `NotchHomeView`, `AgentsTabView`, and the full-window
//  Shelf grid (`ShelfWindowView`). No second renderer for any tab.
//
//  Canvas is solid `.black` to match the notch panel (cohesion over the generic
//  "never pure black" rule). The shared tabs are reused via the `.window`
//  surface flag, which switches off the notch-only collapse blur/suppression.
//
//  The shared `GhostwireViewModel` (the primary notch VM, held by the session
//  bridge) is injected so `AgentsTabView`/`NotchHomeView` find their
//  `@EnvironmentObject`. When it isn't available yet (app still launching) the
//  window falls back to a Shelf-only view, which needs no VM.
//

import SwiftUI

// MARK: - Tabs

enum GhostwireWindowTab: String, CaseIterable, Identifiable {
    case agents, shelf, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agents: return "Agents"
        case .shelf: return "Shelf"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .agents: return "sparkles"
        case .shelf: return "tray.full"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Root

struct GhostwireWindowView: View {
    /// Resolved once per appearance from the session bridge (the primary notch
    /// VM owns the app's live state). Captured into @State so a transient nil
    /// during launch doesn't tear down the tabs after they've mounted.
    @State private var vm: GhostwireViewModel?
    @State private var tab: GhostwireWindowTab = .shelf
    // GW-223: the window's OWN agent chat-navigation state, independent of the
    // notch's shared panel VM — so each surface can sit on a different chat.
    @StateObject private var agentsPanelVM = AgentPanelViewModel()

    var body: some View {
        HStack(spacing: 0) {
            GhostwireWindowSidebar(selection: $tab)
            Divider().overlay(Color.white.opacity(0.07))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.ghostwireSurface, .window)
        .onAppear {
            if vm == nil { vm = GhostwireSessionBridge.shared.ghostwireViewModel }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch tab {
            case .shelf:
                ShelfWindowView()
            case .agents:
                if let vm {
                    AgentsTabView(panelViewModel: agentsPanelVM)
                        .environmentObject(vm)
                        .windowTabFrame(alignment: .topLeading)
                } else {
                    unavailable("Agents")
                }
            case .settings:
                // Settings on a black canvas with a horizontal 8-tab bar (no
                // second sidebar), modules folded into one tab. Real Sparkle
                // updater wired into the About pane.
                WindowSettingsView(updaterController: SettingsWindowController.shared.sharedUpdaterController)
            }
        }
        // emil: tab switches happen tens of times/day → reduce to a fast
        // opacity crossfade, not a full-window slide (too much travel here).
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: tab)
    }

    private func unavailable(_ name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("\(name) is warming up…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window-scale framing for the reused notch tabs

private extension View {
    /// The notch tabs were laid out for a ~600pt strip. In a 920pt window, cap
    /// them to a readable column and let the rest be negative space (taste:
    /// group with whitespace, don't stretch bars across the full width).
    func windowTabFrame(alignment: Alignment) -> some View {
        self
            .frame(maxWidth: 600, alignment: alignment)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .center ? .center : .top)
            .padding(.horizontal, 28)
            .padding(.top, 36)   // clear the transparent titlebar row
            .padding(.bottom, 20)
    }
}

// MARK: - Sidebar

struct GhostwireWindowSidebar: View {
    @Binding var selection: GhostwireWindowTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Clear the traffic-light row.
            Color.clear.frame(height: 30)

            ForEach(GhostwireWindowTab.allCases) { tab in
                SidebarItem(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selection == tab
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = tab }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }
}

private struct SidebarItem: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarButtonStyle())
    }
}

/// Tactile press feedback (emil/taste: buttons must feel responsive).
private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
