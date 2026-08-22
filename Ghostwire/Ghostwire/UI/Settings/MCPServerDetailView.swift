//
//  MCPServerDetailView.swift
//  Ghostwire
//
//  GW-255: the server drill-in. Was a `.sheet(item:)` with a `Done` button —
//  §8.6 called it "a drill-in wearing a sheet" and handed the fix here. Every
//  control inside writes through immediately, so there was never anything for
//  Cancel to mean.
//
//  It renders as pane CONTENT, not as a modal: `MCPSettingsView` swaps it in
//  and supplies the back affordance. That divergence from §8.6's "come back via
//  the navigation bar" is deliberate — the Settings shell is a
//  `NavigationSplitView` whose detail is a switch on a sidebar string, so there
//  is no navigation bar to come back through.
//
//  Annotation badges are UI bias only, never a security boundary — the
//  allowlist is enforced in `MCPClientService.callAllowedTool`.
//

import MCP
import SwiftUI

struct MCPServerDetailView: View {
    let serverID: UUID
    @ObservedObject var model: MCPPaneModel
    /// Called after the server is removed — the pane has to go back, because
    /// the thing it was showing no longer exists.
    var onRemoved: () -> Void = {}

    @ObservedObject private var service = MCPClientService.shared
    @State private var confirmRemove = false

    private var config: MCPServerConfig? { service.store.server(id: serverID) }
    private var runtime: MCPServerRuntime? { service.runtime(id: serverID) }

    private var grouping: MCPToolGrouping {
        guard let runtime, let config else {
            return MCPToolGrouping(sections: [], isCategorized: false, categoryCoverage: 0)
        }
        return MCPToolGrouping.build(tools: runtime.tools, serverName: config.name)
    }

    var body: some View {
        Form {
            connectionSection
            if let config, let runtime, !runtime.tools.isEmpty {
                allowlistSections(config: config)
            } else if runtime?.status.isConnected == true {
                noToolsSection
            }
            removeSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Connection

    /// ONE row, not four.
    ///
    /// This used to stack a lone `Hosted` badge, a lone Test button, a
    /// label/value URL row, and a sentence explaining what "hosted" means —
    /// four left-aligned things down the page with a mostly empty right half.
    /// Everything identifying the server now sits on one line, and the action
    /// sits at its end where actions belong.
    ///
    /// The transport explanation ("Reached over the network. Nothing runs on
    /// this Mac.") is GONE from the page, not lost: it is the badge's `.help`
    /// tooltip, which is where a definition of a label belongs. It mattered
    /// once because the badge was the only signal that a server could execute
    /// something locally — that is still true, and still one hover away.
    @ViewBuilder private var connectionSection: some View {
        if let config {
            Section {
                // Only when there is something to say or do. Connected + no
                // action = the header's tool count already said it.
                if runtime?.status.isConnected != true {
                    HStack(spacing: 8) {
                        if runtime?.status == .connecting {
                            ProgressView().controlSize(.small).frame(width: 8, height: 8)
                        } else {
                            SettingsStateDot(
                                severity: runtime?.status.severity ?? .inert, caption: statusText)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(statusText)
                                .foregroundStyle(
                                    statusNeedsTint ? statusSeverity.color : Color.primary)
                            if let remedy = statusRemedy {
                                Text(remedy).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let action = connectionAction {
                            Button(action.title) {
                                if action.trustFirst {
                                    service.trustCurrentCommand(serverID: serverID)
                                }
                                Task { await service.connectInteractively(id: serverID) }
                            }
                            .disabled(runtime?.status == .connecting)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if case .failed(let reason) = runtime?.status {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsStateColors.error)
                        .textSelection(.enabled)
                }

                // Identity + action on one line: what it is, where it is, and
                // the one thing you can do about it.
                HStack(spacing: 10) {
                    MCPTransportBadge(transport: config.transport)
                    Text(connectionInfo)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                }
                .padding(.vertical, 2)

                // The result lands next to the thing it is about — the old
                // per-tool Run put its output below the remove button, off the
                // bottom of a 58-tool page.
                if let result = model.testResult {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        SettingsStateDot(
                            severity: result.failed ? .error : .ok,
                            caption: result.failed ? "Test failed" : "Test passed")
                        Text("\(result.tool) — \(result.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                result.failed ? SettingsStateColors.error : .secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Clear") { model.testResult = nil }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusSeverity: SettingsStateSeverity { runtime?.status.severity ?? .inert }
    private var statusNeedsTint: Bool { statusSeverity.requiresCaption }

    private var statusText: String {
        switch runtime?.status {
        case .connected(let count): return "Connected — \(count) tool\(count == 1 ? "" : "s")"
        case .connecting: return "Connecting…"
        case .needsAuth: return "Needs authorization"
        case .needsTrust: return "Not trusted yet"
        case .failed: return "Couldn't connect"
        case .disconnected, nil: return "Disconnected"
        }
    }

    /// §8.4: a state the user can fix ships its remedy next to it.
    private var statusRemedy: String? {
        switch runtime?.status {
        case .needsTrust: return "Review the command below before this server may run."
        case .needsAuth: return "Sign in to the service to continue."
        default: return nil
        }
    }

    private var connectionAction: (title: String, trustFirst: Bool)? {
        switch runtime?.status {
        case .connected: return nil  // nothing to do — don't offer a no-op
        case .needsAuth: return ("Authorize", false)
        case .needsTrust: return ("Trust & Connect", true)
        case .connecting: return nil
        case .failed, .disconnected, nil: return ("Reconnect", false)
        }
    }

    private var connectionInfo: String {
        switch config?.transport {
        case .http(let endpoint): return endpoint.absoluteString
        case .stdio(let command, let arguments, _):
            return ([config?.resolvedExecutablePath ?? command] + arguments)
                .joined(separator: " ")
        case nil: return ""
        }
    }

    // MARK: - Allowlist

    @ViewBuilder
    private func allowlistSections(config: MCPServerConfig) -> some View {
        let grouping = self.grouping
        ForEach(grouping.sections) { section in
            Section {
                if section.isCategorized {
                    ForEach(section.categories) { group in
                        categoryHeaderRow(group: group)
                        ForEach(group.tools) { item in
                            toolRow(item: item, config: config, indented: true)
                        }
                    }
                } else {
                    ForEach(section.tools) { item in
                        toolRow(item: item, config: config, indented: false)
                    }
                }
            } header: {
                sectionHeader(section: section, config: config)
            } footer: {
                sectionFooter(section: section, config: config)
            }
        }
    }

    private func sectionHeader(section: MCPCapabilitySection, config: MCPServerConfig)
        -> some View {
        let names = section.toolNames
        let allOn = names.allSatisfy { config.allowedTools.contains($0) }
        return HStack(spacing: 8) {
            Text(section.kind.title)
                .font(.system(size: 13, weight: .semibold))
            // "N of M" per section, instead of one server-wide total in the
            // pane header. Says the same thing where the decision is made, and
            // frees the header's action slot for Disconnect.
            Text("\(allowedCount(section, config: config)) of \(section.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // macOS `Form` has a fixed inter-section gap and exposes no
                // knob for it (`listSectionSpacing` is iOS-only), so the header
                // pulls up into it. Without this, three short sections read as
                // three separate screens.
                .padding(.top, -6)
            Spacer()
            // REMOVE ALL on every section; ALLOW ALL only on Read.
            //
            // The asymmetry is the point: narrowing permissions is always safe,
            // widening them is the thing `allowedTools` exists to gate. A
            // "Allow all" over Write would hand every connected agent every
            // mutating tool in one click, which is what read-only-only bulk
            // allow has always prevented (GW-255).
            if section.canBulkAllow {
                Button(allOn ? "Remove all" : "Allow all") {
                    setAllowed(names, allowed: !allOn)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if allowedCount(section, config: config) > 0 {
                Button("Remove all") { setAllowed(names, allowed: false) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sectionFooter(section: MCPCapabilitySection, config: MCPServerConfig) -> some View {
        if section.kind != .read, allowedCount(section, config: config) > 0 {
            Label(
                consequenceCopy(for: section.severestCapability),
                systemImage: "exclamationmark.shield"
            )
            .font(.system(size: 12))
            .foregroundStyle(SettingsStateColors.attention)
            .leadingFooter()
        }
    }

    private func consequenceCopy(for capability: MCPToolCapability) -> String {
        let name = config?.name ?? "this server"
        switch capability {
        case .destructive: return "These can change or delete things in \(name)."
        case .unclassified: return "Ghostwire couldn't tell what these do."
        default: return "These can write to \(name)."
        }
    }

    private func allowedCount(_ section: MCPCapabilitySection, config: MCPServerConfig) -> Int {
        section.toolNames.filter { config.allowedTools.contains($0) }.count
    }

    private func categoryHeaderRow(group: MCPToolCategoryGroup) -> some View {
        return HStack(spacing: 6) {
            Text(group.title)
                .font(.system(size: 12))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("\(group.tools.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            // No bulk control on a SUBSECTION. The section above already has
            // one, and two "Allow all"s 30pt apart with different scopes is a
            // way to widen more than you meant to.
        }
        .padding(.top, 2)
    }

    /// One tool. The switch is the only control on the title line; Run and the
    /// Feed binding drop to a secondary line that exists only once allowed.
    @ViewBuilder
    private func toolRow(item: MCPGroupedTool, config: MCPServerConfig, indented: Bool) -> some View {
        let isAllowed = config.allowedTools.contains(item.name)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Claude's connector UI shows the TITLE and nothing else, and
                // it reads better: a wire name in mono plus a description
                // truncated mid-sentence gave two unreadable things where one
                // readable one fits. The description moves to the tooltip; the
                // wire name is still what the badge and Run act on.
                HStack(spacing: 6) {
                    Text(item.tool.displayTitle)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    MCPCapabilityBadge(capability: item.capability, source: item.source)
                }
                .help(item.tool.description.map { "\(item.name)\n\n\($0)" } ?? item.name)
                Spacer(minLength: 8)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isAllowed },
                        set: { setAllowed([item.name], allowed: $0) }
                    )
                )
                .toggleStyle(.switch)
                // NOT `.mini`. AppKit squashes the mini switch's knob into an
                // oval rather than scaling it down as a circle — visible the
                // moment you zoom in. `.small` keeps a round knob.
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("Allow \(item.name)")
                .help("Allow Ghostwire to call this tool")
            }

        }
        .padding(.vertical, 1)
        .padding(.leading, indented ? 10 : 0)
    }

    // MARK: - Empty / output / remove

    private var noToolsSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Connected, but this server offers no tools.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    /// ONE state-driven action, matching `connectionAction` above: **Disconnect
    /// while connected, Remove while not** (Keelan, 2026-08-21).
    ///
    /// They are genuinely different — Disconnect drops the live session and
    /// keeps the server, its allowlist and its Feed cards; Remove forgets all
    /// of it. Showing only the one that fits the current state means a live
    /// connection cannot be deleted in a single click: you disconnect first,
    /// then remove. That two-step is the point, not a cost.
    ///
    /// Remove is the only RED control on this pane. Everything else is
    /// reversible; this is the one that isn't.
    @ViewBuilder private var removeSection: some View {
        if runtime?.status.isConnected == true {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Disconnect")
                        Text("Keeps this server and everything you've allowed.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") {
                        Task { await service.disconnect(id: serverID) }
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remove this server")
                        Text("The tools you allowed and its Feed cards go with it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .tint(SettingsStateColors.error)
                }
                .padding(.vertical, 2)
            }
            // A confirmation dialog is safe HERE and only here: Settings is an
            // ordinary NSWindow. Presenting one while the notch panel is open
            // deadlocks (macos-conventions.md §3).
            .confirmationDialog(
                "Remove \(config?.name ?? "this server")?",
                isPresented: $confirmRemove, titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    service.removeServer(id: serverID)
                    onRemoved()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Ghostwire stops calling it, and its Feed cards disappear.")
            }
        }
    }

    // MARK: - Actions

    /// One store write for the whole selection — see `setToolsAllowed`.
    private func setAllowed(_ names: [String], allowed: Bool) {
        service.setToolsAllowed(serverID: serverID, tools: names, allowed: allowed)
        restartFeed()
    }

    /// Rebuild the Source list now rather than at the next poll, so a binding
    /// shows up in the Feed while the user is still looking at this pane.
    ///
    /// Redundant with `MCPClientService.feedConfigDidChange`, which the
    /// coordinator now subscribes to — kept because it's immediate where the
    /// subscription is debounced, and because it costs nothing if the rebuild
    /// has already happened.
    private func restartFeed() {
        FeedSourceCoordinator.shared.start()
    }
}

// MARK: - Badges

/// §8.2 badge: `caption2.monospaced()`, r4, h5/v2.
///
/// An INFERRED capability is outlined rather than filled. It isn't a new signal
/// — it's the same badge with its provenance shown, because "the server told
/// us this only reads" and "we guessed from the verb" are different promises
/// and the user is making a security decision on one of them.
struct MCPCapabilityBadge: View {
    let capability: MCPToolCapability
    let source: MCPCapabilitySource

    var body: some View {
        Text(capability.badge)
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                if source == .declared {
                    RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15))
                } else {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.5), lineWidth: 1)
                }
            }
            .foregroundStyle(tint)
            .accessibilityLabel(
                source == .declared
                    ? capability.badge
                    : "\(capability.badge), worked out from the tool's name")
            .help(
                source == .declared
                    ? "The server declares this."
                    : "This server declares nothing — worked out from the tool's name.")
    }

    private var tint: Color {
        switch capability {
        case .readOnly: return SettingsStateColors.ok
        case .writes: return .secondary
        case .destructive: return SettingsStateColors.error
        case .unclassified: return SettingsStateColors.attention
        }
    }
}

/// GW-255 terminology fix: `stdio` / `http` told a user nothing. What they
/// actually need to know is whether this runs a program on their Mac.
struct MCPTransportBadge: View {
    let transport: MCPTransportConfig

    var body: some View {
        Text(transport.displayLabel)
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .help(transport.explanation)
    }
}

// MARK: - Tool count (pane header)

/// The connected tool count, rendered in `WindowPaneHeader`'s action slot while
/// a server is drilled into. Its own view so the header can read live runtime
/// state without `GhostwireWindowView` observing `MCPClientService`.
/// The drill-in's header action: the ONE state-driven control, plus an
/// overflow for the rare things.
///
/// Disconnect while connected, Reconnect/Authorize otherwise — Remove stays at
/// the bottom of the page, because forgetting a server is not a thing you do
/// from a toolbar. Test lives in the overflow: it is a diagnostic you reach for
/// when something looks wrong, not a step in connecting, and a green dot
/// already says the handshake worked (Keelan, 2026-08-22).
struct MCPServerHeaderActions: View {
    let serverID: UUID
    @ObservedObject var model: MCPPaneModel
    @ObservedObject private var service = MCPClientService.shared

    private var runtime: MCPServerRuntime? { service.runtime(id: serverID) }

    var body: some View {
        HStack(spacing: 8) {
            if runtime?.status.isConnected == true {
                Button("Disconnect") {
                    Task { await service.disconnect(id: serverID) }
                }
            }
            // Connected ONLY. `MCPClientService` keeps the session and tool
            // list after a transient call failure but marks the runtime
            // `.failed`, and a passing `callAllowedTool` records health without
            // restoring that status — so testing in that state produced "Test
            // passed" sitting beside "Couldn't connect · Reconnect" (Codex P2,
            // 2026-08-22). Moving Test into the header dropped the guard the
            // inline button used to have; this is it back.
            if runtime?.status.isConnected == true, model.testableTool(for: serverID) != nil {
                Menu {
                    Button(model.isTesting ? "Testing…" : "Test connection") {
                        Task { await model.runTest(serverID: serverID) }
                    }
                    .disabled(model.isTesting)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            }
        }
    }
}

struct MCPToolCountLabel: View {
    let serverID: UUID
    @ObservedObject private var service = MCPClientService.shared

    init(serverID: UUID) { self.serverID = serverID }

    private var runtime: MCPServerRuntime? { service.runtime(id: serverID) }

    var body: some View {
        if case .connected(let count) = runtime?.status,
            let config = service.store.server(id: serverID)
        {
            HStack(spacing: 6) {
                SettingsStateDot(severity: .ok, caption: "Connected")
                // The ALLOWED count over the advertised one: a connected server
                // with an empty allowlist can't be called, so a bare "58 tools"
                // would overclaim (GW-255).
                Text("\(config.allowedTools.count) of \(count) tools")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
