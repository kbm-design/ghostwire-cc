//
//  GhostwireWindowView.swift
//  Ghostwire
//
//  GW-223. Root of the detached Ghostwire window: a left source-list sidebar
//  (Feed / Agents / Shelf / Settings) over a black content area that hosts the
//  SAME tab views the notch uses — `FeedSurfaceView`, `AgentsTabView`, and the
//  full-window Shelf grid (`ShelfWindowView`). No second renderer for any tab.
//
//  Settings is a disclosure group in that sidebar: this window is now the app's
//  only settings surface, so its panes are sidebar children rather than a
//  standalone window's own source list.
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
    /// `.sessions` has no nav row: the Sessions list at the top of the sidebar is
    /// how you get there, and a session IS the destination. It stays a tab
    /// because it is still a content pane. `.agents` is the separate thing —
    /// how agents are wired up (hooks, approval mode, alerts), which was a
    /// Settings pane until it earned a place of its own.
    case feed, sessions, agents, shelf, mcp, settings

    var id: String { rawValue }

    /// Rows shown in the sidebar's nav block, in order. `.sessions` is covered by
    /// the Sessions list above them, and Settings is a disclosure below.
    static let navRows: [GhostwireWindowTab] = [.feed, .agents, .shelf, .mcp]

    var label: String {
        switch self {
        case .feed: return "Cards"
        case .sessions: return "Sessions"
        case .agents: return "Agents"
        case .shelf: return "Clipboard"
        case .mcp: return "Connections"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .feed: return "square.grid.2x2"
        case .sessions: return "bubble.left.and.bubble.right"
        case .agents: return "sparkles"
        case .shelf: return "doc.on.clipboard"
        case .mcp: return "point.3.connected.trianglepath.dotted"
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
    /// Shared so other surfaces can open the window on a specific tab/pane.
    @ObservedObject private var nav = GhostwireWindowModel.shared
    // GW-223: the window's OWN agent chat-navigation state, independent of the
    // notch's shared panel VM — so each surface can sit on a different chat.
    @StateObject private var agentsPanelVM = AgentPanelViewModel()
    /// MCP is a top-level destination now, and its pane header renders the Add
    /// control, so the state both halves read is owned here.
    @StateObject private var mcp = MCPPaneModel()

    /// The session the Agents pane is showing, so the sidebar can highlight it.
    private var openSessionID: String? {
        if case .chat(let session) = agentsPanelVM.contentType { return session.sessionId }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            GhostwireWindowSidebar(
                selectedSessionID: openSessionID,
                onOpenSession: { session in
                    agentsPanelVM.showChat(for: session)
                    withAnimation(.easeOut(duration: 0.15)) { nav.tab = .sessions }
                }
            )
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            nav.accentRefresh = UUID()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch nav.tab {
            case .feed:
                // GW-259: cards only — no media controls in the window (they're
                // not useful here). GW-466: FeedPaneView adds the pane header,
                // the floating ＋ and the Add-cards page over the grid.
                FeedPaneView()
                    .tint(.effectiveAccent)
            case .shelf:
                ShelfWindowView()
            case .agents:
                VStack(spacing: 0) {
                    WindowPaneHeader(title: "Agents")
                    AgentsSettings()
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .tint(.effectiveAccent)
            case .sessions:
                if let vm {
                    AgentsTabView(panelViewModel: agentsPanelVM)
                        .environmentObject(vm)
                        .windowTabFrame(alignment: .topLeading)
                } else {
                    unavailable("Agents")
                }
            case .mcp:
                VStack(spacing: 0) {
                    // GW-449: Add moved OUT of the header's action slot to sit
                    // beside search inside the pane. Two Add controls is worse
                    // than either, and the catalog's top row wants search.
                    //
                    // Drilled in, the header becomes the SERVER's: its name as
                    // the title, back to its left, tool count in the slot Add
                    // vacated. The drill-in used to publish its own "‹ Servers"
                    // link inside the content, under a header still reading
                    // "Connections" — two competing answers to "where am I".
                    if let server = mcp.openServer {
                        WindowPaneHeader(
                            title: server.name,
                            onBack: { mcp.openServerID = nil }
                        ) {
                            MCPServerHeaderActions(serverID: server.id, model: mcp)
                        }
                    } else {
                        WindowPaneHeader(title: "Connections")
                    }
                    MCPSettingsView(model: mcp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                // The tint reaches every control beneath it, which is how one
                // screen ended up with six blue things competing (Keelan,
                // 2026-08-22). Accent now means ONE thing here — a toggle that
                // is ON — matching how Linear and Qatalog handle the same
                // screen. Text actions opt out with `.foregroundStyle`.
                .tint(.effectiveAccent)
            case .settings:
                WindowSettingsView()
            }
        }
        // emil: tab switches happen tens of times/day → reduce to a fast
        // opacity crossfade, not a full-window slide (too much travel here).
        .transition(.opacity)
        .animation(.easeOut(duration: 0.15), value: nav.tab)
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
    @ObservedObject private var nav = GhostwireWindowModel.shared
    @ObservedObject private var updates = UpdateStatusModel.shared
    /// Local, not persisted — the window reopens on its last tab anyway, and an
    /// expanded tree that outlives the session is noise on the next launch.
    @State private var settingsExpanded = false

    let selectedSessionID: String?
    let onOpenSession: (SessionState) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    // Clear the traffic-light row.
                    Color.clear.frame(height: 30)

                    // Live sessions own the top of the sidebar: they're what you
                    // came here for, and one of them may be waiting on you.
                    SessionsSidebarSection(
                        onOpen: onOpenSession,
                        selectedSessionID: nav.tab == .sessions ? selectedSessionID : nil
                    )

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 10)
            }

            navBlock
            footer
        }
        .frame(width: 224)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        // Another surface (menu bar / notch menu / onboarding) can point the
        // window at Settings — the tree has to open to show where it landed.
        .onAppear { if nav.tab == .settings { settingsExpanded = true } }
        .onChange(of: nav.tab) { _, tab in
            if tab == .settings {
                withAnimation(.easeOut(duration: 0.15)) { settingsExpanded = true }
            }
        }
    }

    // MARK: Nav

    /// Pushed to the bottom, under the sessions. These are places you visit
    /// occasionally; the sessions are the thing you came for.
    private var navBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(GhostwireWindowTab.navRows) { tab in
                SidebarItem(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: nav.tab == tab
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { nav.tab = tab }
                }
            }

            settingsSection
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: Settings disclosure

    @ViewBuilder
    private var settingsSection: some View {
        SidebarItem(
            label: GhostwireWindowTab.settings.label,
            systemImage: GhostwireWindowTab.settings.systemImage,
            isSelected: nav.tab == .settings,
            trailing: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
            }
        ) {
            withAnimation(.easeOut(duration: 0.15)) {
                // Coming from another tab: select Settings and open the tree.
                // Already on Settings: the row is the collapse control.
                if nav.tab == .settings {
                    settingsExpanded.toggle()
                } else {
                    nav.tab = .settings
                    settingsExpanded = true
                }
            }
        }

        if settingsExpanded {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPane.allCases) { pane in
                    SidebarItem(
                        label: pane.label,
                        systemImage: pane.systemImage,
                        isSelected: nav.tab == .settings && nav.settingsPane == pane,
                        indent: 18
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            nav.tab = .settings
                            nav.settingsPane = pane
                        }
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Footer

    /// Pinned below everything, so Quit is always in the same place. It was a
    /// `.toolbar` button on the General pane, which put it in the titlebar beside
    /// the traffic lights — one slot that other panes then took over. The version
    /// + update line sits with it because "what am I running, is it current" and
    /// "get me out of here" are the same kind of question.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(versionLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                updateStatusRow
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 7)

            SidebarItem(label: "Quit Ghostwire", systemImage: "power", isSelected: false) {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 10)
    }

    private var versionLine: String {
        "Ghostwire \(Bundle.main.releaseVersionNumber ?? "—")"
    }

    /// Renders nothing until Sparkle has actually reported — see UpdateStatusModel.
    @ViewBuilder
    private var updateStatusRow: some View {
        switch updates.status {
        case .unknown:
            EmptyView()
        case .upToDate:
            statusLine(color: .green, text: "Up to date", emphasised: false)
        case .available:
            Button {
                nav.updaterController?.updater.checkForUpdates()
            } label: {
                statusLine(color: .orange, text: "Update available", emphasised: true)
            }
            .buttonStyle(.plain)
        case .failed:
            statusLine(color: .red, text: "Update check failed", emphasised: false)
        }
    }

    private func statusLine(color: Color, text: String, emphasised: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: emphasised ? .medium : .regular))
                .foregroundStyle(emphasised ? AnyShapeStyle(color) : AnyShapeStyle(Color.white.opacity(0.42)))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

private struct SidebarItem<Trailing: View>: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let indent: CGFloat
    let trailing: () -> Trailing
    let action: () -> Void

    init(
        label: String,
        systemImage: String,
        isSelected: Bool,
        indent: CGFloat = 0,
        @ViewBuilder trailing: @escaping () -> Trailing,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.indent = indent
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: indent > 0 ? 11 : 13, weight: .medium))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: indent > 0 ? 12 : 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing()
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
            .padding(.leading, 10 + indent)
            .padding(.trailing, 10)
            .frame(height: indent > 0 ? 28 : 32)
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

/// Rows with no trailing accessory (everything but the Settings disclosure).
private extension SidebarItem where Trailing == EmptyView {
    init(
        label: String,
        systemImage: String,
        isSelected: Bool,
        indent: CGFloat = 0,
        action: @escaping () -> Void
    ) {
        self.init(
            label: label,
            systemImage: systemImage,
            isSelected: isSelected,
            indent: indent,
            trailing: { EmptyView() },
            action: action
        )
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
