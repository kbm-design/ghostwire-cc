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
    /// Called after the server is removed — the pane has to go back, because
    /// the thing it was showing no longer exists.
    var onRemoved: () -> Void = {}

    @ObservedObject private var service = MCPClientService.shared
    @State private var runOutput: RunOutput?
    @State private var runningTool: String?
    @State private var confirmRemove = false

    private struct RunOutput: Identifiable {
        let id = UUID()
        let tool: String
        let text: String
        let failed: Bool
    }

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
            if let output = runOutput { runOutputSection(output) }
            removeSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Connection

    @ViewBuilder private var connectionSection: some View {
        if let config {
            Section {
                HStack(spacing: 8) {
                    if runtime?.status == .connecting {
                        ProgressView().controlSize(.small).frame(width: 8, height: 8)
                    } else {
                        SettingsStateDot(
                            severity: runtime?.status.severity ?? .inert, caption: statusText)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(statusText)
                            .foregroundStyle(statusNeedsTint ? statusSeverity.color : Color.primary)
                        if let remedy = statusRemedy {
                            Text(remedy).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // ONE state-driven action, not three buttons. "Test" on a
                    // server that already says "Connected — 36 tools" tests
                    // nothing, so it only appears when there's something to fix.
                    if let action = connectionAction {
                        Button(action.title) {
                            if action.trustFirst { service.trustCurrentCommand(serverID: serverID) }
                            Task { await service.connectInteractively(id: serverID) }
                        }
                        .disabled(runtime?.status == .connecting)
                    }
                }
                .padding(.vertical, 2)

                if case .failed(let reason) = runtime?.status {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(SettingsStateColors.error)
                        .textSelection(.enabled)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(config.transport.isLocal ? "Command" : "URL")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(connectionInfo)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(config.name)
                    MCPTransportBadge(transport: config.transport)
                }
            } footer: {
                Text(config.transport.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
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
                        categoryHeaderRow(group: group, section: section, config: config)
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
            Text(section.capability.sectionTitle)
            Text("\(section.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            if section.canBulkAllow {
                // Bulk allow exists only for read-only tools. `allowedTools` is
                // also the gateway floor, so mutating and unknown tools need a
                // visible one-tool decision.
                Button(bulkTitle(section: section, allOn: allOn)) {
                    setAllowed(names, allowed: !allOn)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// The read-only bulk action carries its count because that is the only
    /// section where bulk widening is offered, and the number is the reassurance.
    private func bulkTitle(section: MCPCapabilitySection, allOn: Bool) -> String {
        if allOn { return "Remove all" }
        return "Allow all \(section.count)"
    }

    @ViewBuilder
    private func sectionFooter(section: MCPCapabilitySection, config: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // §8.5: ONE consequence warning, on the section that earns it — and
            // it's conditional, so a read-only server never sees it.
            if section.capability.mutates, allowedCount(section, config: config) > 0 {
                Label(consequenceCopy(for: section.capability), systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(SettingsStateColors.attention)
            }
            if section.isEntirelyInferred {
                Text(
                    "This server doesn't say which of its tools only read — these are worked out "
                    + "from each tool's name, so check anything you're unsure about."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if section.capability == .unclassified {
                Text("Ghostwire couldn't tell what these do. Allow them one at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .leadingFooter()
    }

    private func consequenceCopy(for capability: MCPToolCapability) -> String {
        let verb = capability == .destructive ? "change or delete things in" : "write to"
        let name = config?.name ?? "this server"
        return "These \(verb) \(name). Anything allowed here is also reachable by agents "
            + "connected to the gateway."
    }

    private func allowedCount(_ section: MCPCapabilitySection, config: MCPServerConfig) -> Int {
        section.toolNames.filter { config.allowedTools.contains($0) }.count
    }

    private func categoryHeaderRow(
        group: MCPToolCategoryGroup, section: MCPCapabilitySection, config: MCPServerConfig
    )
        -> some View {
        let names = group.toolNames
        let allOn = names.allSatisfy { config.allowedTools.contains($0) }
        return HStack(spacing: 6) {
            Text(group.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("\(group.tools.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            // The catch-all gets no bulk control: "Allow all 6 unrelated
            // things" isn't a meaningful action. Mutating groups get no bulk
            // control either, even when a resource category is coherent.
            if group.canBulkAllow(in: section) {
                Button(allOn ? "Remove all" : "Allow all \(group.tools.count)") {
                    setAllowed(names, allowed: !allOn)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(.top, 4)
    }

    /// One tool. The switch is the only control on the title line; Run and the
    /// Feed binding drop to a secondary line that exists only once allowed.
    @ViewBuilder
    private func toolRow(item: MCPGroupedTool, config: MCPServerConfig, indented: Bool) -> some View {
        let isAllowed = config.allowedTools.contains(item.name)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.name).font(.body.monospaced()).lineLimit(1)
                        MCPCapabilityBadge(capability: item.capability, source: item.source)
                    }
                    if let description = item.tool.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isAllowed },
                        set: { setAllowed([item.name], allowed: $0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Allow \(item.name)")
                .help("Allow Ghostwire to call this tool")
            }

            if isAllowed { secondaryLine(tool: item.tool, config: config) }
        }
        .padding(.vertical, 2)
        .padding(.leading, indented ? 10 : 0)
    }

    // MARK: - GW-214: bind a tool as a feed card

    /// Run + the feed binding. Only reachable once the tool is allowed.
    @ViewBuilder
    private func secondaryLine(tool: MCPToolInfo, config: MCPServerConfig) -> some View {
        let binding = config.feedTools?.first { $0.tool == tool.name }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button(runningTool == tool.name ? "Running…" : "Run") {
                    Task { await run(tool: tool.name) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(runningTool != nil)
                .help("Call this tool once and show the raw result")

                if tool.isFeedCandidate {
                    // The good path: no arguments to supply, so binding is one
                    // click and nothing else appears.
                    Toggle(
                        "Show in Feed",
                        isOn: Binding(
                            get: { binding != nil },
                            set: {
                                service.setFeedTool(
                                    serverID: serverID, tool: tool.name, bound: $0)
                                restartFeed()
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                } else {
                    // Needs input, so it's a QUESTION, not a standing value.
                    // Reachable, but never the suggested path.
                    needsArgumentsControl(tool: tool, isBound: binding != nil)
                }
                Spacer(minLength: 0)
            }

            if let binding {
                if tool.isFeedCandidate {
                    // Optional parameters, collapsed. The candidacy rule means
                    // the common path needs none — but `list_issues` without
                    // `assignee: me` returns the whole team's work, so scoping
                    // has to be REACHABLE even though it isn't the default.
                    //
                    // A JSON box is a placeholder control, not the answer: the
                    // tool's inputSchema already describes each parameter's type
                    // and enum, so these should be generated native controls.
                    // That's GW-333.
                    DisclosureGroup("Options") {
                        feedArgumentsField(binding: binding, tool: tool)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    feedArgumentsField(binding: binding, tool: tool)
                }
            }
        }
        .padding(.leading, 2)
    }

    /// A tool with required inputs re-asks one frozen question on every poll.
    /// Sometimes that's genuinely what you want (a pinned repo, a fixed
    /// account), so it stays possible — behind a disclosure that says what
    /// you're signing up for rather than an icon that invites it.
    private func needsArgumentsControl(tool: MCPToolInfo, isBound: Bool) -> some View {
        HStack(spacing: 6) {
            Toggle(
                "Show in Feed",
                isOn: Binding(
                    get: { isBound },
                    set: {
                        service.setFeedTool(serverID: serverID, tool: tool.name, bound: $0)
                        restartFeed()
                    }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)

            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(SettingsStateColors.attention)
                .help(
                    "Needs \(tool.requiredInputs.joined(separator: ", ")) — this asks a fixed question on every refresh. Best for a pinned subject, not a search."
                )
        }
    }

    /// Arguments for the scheduled call. Only shown for tools that require
    /// input; a feed candidate never needs it, which is the point.
    private func feedArgumentsField(binding: MCPFeedToolBinding, tool: MCPToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Arguments").font(.caption2).foregroundStyle(.secondary)
                FeedArgumentsField(
                    placeholder: Self.argumentsPlaceholder(for: tool),
                    initialText: binding.argumentsJSON,
                    onCommit: { text in
                        service.setFeedToolArguments(
                            serverID: serverID, tool: binding.tool, argumentsJSON: text)
                    }
                )
                .id(binding.tool)
            }
            if !binding.hasValidArguments {
                Text("Not a JSON object — the tool will be called with no arguments.")
                    .font(.caption2).foregroundStyle(SettingsStateColors.attention)
            } else if !binding.argumentsJSON.trimmingCharacters(in: .whitespaces).isEmpty,
                binding.argumentsJSON.trimmingCharacters(in: .whitespaces) != "{}" {
                // These are stored in ~/.ghostwire/mcp-servers.json, which is
                // otherwise guaranteed secret-free (env values and tokens live
                // in the Keychain). Say so rather than let a token land there
                // silently.
                Text("Saved in plain text — put credentials in the server's auth settings, not here.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !tool.requiredInputs.isEmpty {
                // The empty `{}` default is invalid for this tool by definition,
                // so say what's missing instead of waiting for the server to
                // return a -32602 the user has to decode. Feed candidates
                // require nothing, so they never see this.
                Text("Requires \(tool.requiredInputs.joined(separator: ", ")).")
                    .font(.caption2).foregroundStyle(SettingsStateColors.attention)
            }
        }
        .padding(.leading, 2)
    }

    /// A filled-in shape beats `{}` — the user shouldn't have to infer the
    /// JSON from an error message.
    static func argumentsPlaceholder(for tool: MCPToolInfo) -> String {
        guard !tool.requiredInputs.isEmpty else { return "{}" }
        let pairs = tool.requiredInputs.map { "\"\($0)\": \"\"" }.joined(separator: ", ")
        return "{\(pairs)}"
    }

    // MARK: - Empty / output / remove

    private var noToolsSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("This server is connected but offers no tools.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func runOutputSection(_ output: RunOutput) -> some View {
        Section {
            ScrollView {
                Text(output.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        } header: {
            HStack {
                Text("Result — \(output.tool)")
                if output.failed {
                    Text("failed").foregroundStyle(SettingsStateColors.error)
                }
                Spacer()
                Button("Clear") { runOutput = nil }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    /// §8.1 puts a destructive action in a sheet's button bar; §8.6 removes the
    /// button bar from a drill-in, so it has no specified home. It gets its own
    /// trailing section — furthest from anything routine, and it still reads as
    /// part of the page rather than floating over it. (Flagged to GW-356.)
    private var removeSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Remove this server")
                    Text("Its allowlist and any Feed cards go with it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove…", role: .destructive) { confirmRemove = true }
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
            Text("Ghostwire stops calling it and any Feed cards from it disappear.")
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

    @MainActor
    private func run(tool: String) async {
        runningTool = tool
        defer { runningTool = nil }
        do {
            // Empty object, not nil: strict servers (zod-validated) reject a
            // missing arguments field with "expected object, received undefined".
            let output = try await service.callAllowedTool(
                serverID: serverID, name: tool, arguments: [:])
            var sections: [String] = []
            if let structured = output.structuredContent {
                sections.append("structuredContent:\n\(structured)")
            }
            if !output.textRepresentation.isEmpty {
                sections.append("text:\n\(output.textRepresentation)")
            }
            runOutput = RunOutput(
                tool: tool,
                text: sections.isEmpty ? "(empty result)" : sections.joined(separator: "\n\n"),
                failed: false)
        } catch {
            runOutput = RunOutput(tool: tool, text: error.localizedDescription, failed: true)
        }
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
            .font(.caption2)
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
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .help(transport.explanation)
    }
}

// MARK: - Arguments field

/// A JSON text field that commits on Return **or on losing focus**.
///
/// Binding straight through to the store looked simpler and was wrong twice:
/// it wrote `mcp-servers.json` on every keystroke, and — because only
/// `.onSubmit` rebuilt the Sources — clicking away after typing persisted the
/// new arguments while the running Source kept calling with the old ones until
/// an unrelated restart. Buffering locally and committing on both paths fixes
/// both. (Codex P2, 2026-07-29.)
private struct FeedArgumentsField: View {
    let placeholder: String
    let initialText: String
    let onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(placeholder: String, initialText: String, onCommit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.initialText = initialText
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            // The pane can be navigated away from while the field still has
            // focus, which fires no focus-loss event.
            .onDisappear { commit() }
    }

    private func commit() {
        guard text != initialText else { return }
        onCommit(text)
    }
}
