//
//  MCPImportSheet.swift
//  Ghostwire
//
//  GW-332 Phase 1: "found N servers — pick which to add", instead of
//  "go find a URL and paste it".
//
//  Settings is the one surface that follows system light/dark and uses native
//  controls (docs/macos-conventions.md §5), so this is plain SwiftUI with
//  system materials — no notch palette. No NSOpenPanel anywhere: the path is
//  fixed, which also sidesteps the notch window-level deadlock entirely.
//

import SwiftUI

struct MCPImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = MCPClientService.shared

    /// Injectable so previews and a future "import from X" reuse the sheet.
    var configURL: URL = AgentMCPConfigImporter.claudeCodeConfigURL
    var sourceName: String = "Claude Code"

    @State private var discovered: [DiscoveredMCPServer] = []
    @State private var selection: Set<String> = []
    @State private var loadError: String?
    @State private var hasLoaded = false
    @State private var isImporting = false

    /// Already-added and self-reference rows are *reassurance*, not work. Left
    /// inline they made a second visit look like a wall of disabled rows — as
    /// if the servers had been added and then deactivated. They collapse into
    /// a footer count instead, so what's on screen is what there is to decide.
    @State private var showingResolved = false

    private var importable: [DiscoveredMCPServer] { discovered.filter(\.isImportable) }
    private var selectedServers: [DiscoveredMCPServer] {
        importable.filter { selection.contains($0.id) }
    }

    /// Rows worth a decision: addable, plus the ones blocked for a reason the
    /// user could act on.
    private var actionable: [DiscoveredMCPServer] {
        discovered.filter {
            switch $0.blocker {
            case nil, .credentialInCommandLine, .credentialInEndpoint: return true
            case .alreadyAdded, .selfReference: return false
            }
        }
    }

    private var resolved: [DiscoveredMCPServer] {
        discovered.filter { $0.blocker == .alreadyAdded || $0.blocker == .selfReference }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            footnote
            Divider()
            actions
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            load()
        }
    }

    /// Source-neutral title with the source named underneath. Claude Code is
    /// the only reader today, but Codex/Cursor/Claude Desktop are the next
    /// increment — they become additional sections here, not a re-titled sheet.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Import MCP Servers").font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if loadError != nil { return configURL.abbreviatingWithTilde }
        if !hasLoaded { return "Reading \(configURL.abbreviatingWithTilde)…" }
        if discovered.isEmpty { return "No MCP servers in \(configURL.abbreviatingWithTilde)." }
        if importable.isEmpty && actionable.isEmpty {
            // Everything's already here. Say THAT — "none can be added" read as
            // a failure when it was the success case.
            return "Everything in your \(sourceName) config is already in Ghostwire."
        }
        let count = importable.count
        guard count > 0 else {
            return "Nothing new to add from \(sourceName) — see below for why."
        }
        return "\(count) new \(count == 1 ? "server" : "servers") from \(sourceName). "
            + "Nothing is enabled until you say so."
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            message(loadError, symbol: "exclamationmark.triangle", tint: .orange)
        } else if !hasLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if discovered.isEmpty {
            message(
                "Configure a server in \(sourceName) and it'll show up here.",
                symbol: "server.rack", tint: .secondary)
        } else if actionable.isEmpty && !resolved.isEmpty {
            message(
                "All \(resolved.count) servers in your \(sourceName) config are "
                    + "already set up here.",
                symbol: "checkmark.circle", tint: .green)
        } else {
            List {
                Section {
                    ForEach(actionable) { server in
                        row(server)
                    }
                } header: {
                    Label(
                        "\(sourceName) — \(configURL.abbreviatingWithTilde)",
                        systemImage: "doc.text"
                    )
                    .font(.caption)
                }
                if !resolved.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showingResolved) {
                            ForEach(resolved) { server in
                                row(server)
                            }
                        } label: {
                            Text("\(resolved.count) already set up").font(.caption)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ server: DiscoveredMCPServer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { selection.contains(server.id) },
                    set: { isOn in
                        if isOn {
                            selection.insert(server.id)
                        } else {
                            selection.remove(server.id)
                        }
                    })
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!server.isImportable)
            // The checkbox is the only control on the row; without this its
            // meaning is position-only to a screen reader.
            .accessibilityLabel("Add \(server.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(server.isImportable ? .primary : .secondary)
                    badge(server.transportBadge)
                    Spacer(minLength: 0)
                    Text(scopeLabel(server))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(server.scopes.joined(separator: "\n"))
                }
                Text(server.commandLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                notes(server)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard server.isImportable else { return }
            if selection.contains(server.id) {
                selection.remove(server.id)
            } else {
                selection.insert(server.id)
            }
        }
    }

    /// Per-row credential and blocker notes. Pairs every state with words, not
    /// just a tint (docs/macos-conventions.md §6).
    @ViewBuilder
    private func notes(_ server: DiscoveredMCPServer) -> some View {
        if let blocker = server.blocker {
            Label(blocker.reason, systemImage: blockerSymbol(blocker))
                .font(.caption2)
                .foregroundStyle(blocker == .alreadyAdded || blocker == .selfReference
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if !server.environment.isEmpty {
                Label(
                    "Uses \(server.environment.keys.sorted().joined(separator: ", ")) "
                        + "from your \(sourceName) config — copied to your Keychain, "
                        + "not to Ghostwire's config file.",
                    systemImage: "key.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if server.httpAuthToken?.isEmpty == false {
                Label(
                    "Uses the token from your \(sourceName) config — copied to your Keychain.",
                    systemImage: "key.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !server.unmappedHeaderNames.isEmpty {
                Label(
                    "These headers won't carry over: "
                        + server.unmappedHeaderNames.joined(separator: ", ") + ".",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blockerSymbol(_ blocker: DiscoveredMCPServer.Blocker) -> String {
        switch blocker {
        case .alreadyAdded: return "checkmark.circle"
        case .selfReference: return "arrow.triangle.2.circlepath"
        case .credentialInCommandLine, .credentialInEndpoint: return "key.slash"
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
    }

    /// A server found in five projects shouldn't print five paths.
    private func scopeLabel(_ server: DiscoveredMCPServer) -> String {
        if server.scopes.contains(AgentMCPConfigImporter.globalScopeLabel) {
            return AgentMCPConfigImporter.globalScopeLabel
        }
        guard let first = server.scopes.first else { return "" }
        let name = URL(fileURLWithPath: first).lastPathComponent
        return server.scopes.count > 1 ? "\(name) +\(server.scopes.count - 1)" : name
    }

    // MARK: - Footnote + actions

    @ViewBuilder private var footnote: some View {
        if selectedServers.contains(where: {
            if case .stdio = $0.transport { return true } else { return false }
        }) {
            Label(
                "Local commands are added but not run. Each one needs a trust "
                    + "confirmation before Ghostwire will start it.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack {
            if !importable.isEmpty {
                Button(selection.count == importable.count ? "Deselect All" : "Select All") {
                    selection = selection.count == importable.count
                        ? []
                        : Set(importable.map(\.id))
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addButtonTitle) {
                Task { await performImport() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty || isImporting)
        }
    }

    private var addButtonTitle: String {
        switch selection.count {
        case 0: return "Add"
        case 1: return "Add 1 Server"
        default: return "Add \(selection.count) Servers"
        }
    }

    // MARK: - Work

    private func load() {
        do {
            discovered = try AgentMCPConfigImporter.discover(
                claudeCodeConfigAt: configURL, existing: service.store.servers)
            // Pre-select everything importable: the whole point is not typing.
            selection = Set(discovered.filter(\.isImportable).map(\.id))
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func performImport() async {
        isImporting = true
        defer { isImporting = false }
        let added = await service.importServers(selectedServers)
        // Connect only what can't execute code. An stdio server is inert until
        // the user trusts it in the detail view, so connecting it here would
        // just paint every row red with "needsTrust".
        for config in added where config.isTrusted {
            await service.connectInteractively(id: config.id)
        }
        dismiss()
    }
}

extension URL {
    /// `~/.claude.json` reads better than the full home path in UI copy.
    var abbreviatingWithTilde: String { (path as NSString).abbreviatingWithTildeInPath }
}
