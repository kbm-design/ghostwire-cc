//
//  ConnectionsCatalogView.swift
//  Ghostwire
//
//  GW-449 (GW-332 §2): the Connections pane as a connector CATALOG rather than
//  a list of what you already added. Design of record: Paper file
//  `01KY3YDBFGKAY9YZACKQWP3CHD` → page Connectors (4-0) → artboard
//  `Connections — catalog (v1)` @ 920×640.
//
//  Three knowing divergences, all accepted rather than accidental:
//
//  1. **This pane is not a `Form`.** `docs/design-system.md` §8 says every
//     Settings pane is one. A catalog isn't a settings list, and the grouped
//     inset styling fights a card grid. Nothing else in Settings should read
//     this as permission.
//  2. **The Add control sits beside search, not in `WindowPaneHeader`'s action
//     slot.** Two Add controls is worse than either, and search wants the top
//     row anyway. The header keeps only the title.
//  3. **The gateway is not on this pane at all.** Its setup moved to Agents,
//     beside `ShelfAccessSection`. A one-line "Agents can reach N tools"
//     summary was built here and REMOVED: the number is a rollup of three
//     different systems — the `mcpGatewayEnabled` toggle, each server's
//     per-tool `allowedTools` (set in the drill-in), and GW-184's working-set
//     bound — and summing the allowlists reports a CEILING, not what an agent
//     actually sees, because the working set clips it. A wrong number in a
//     quiet line is worse than no line. GW-451 owns deciding what this surface
//     should claim; don't re-add a summary before it does.
//
//  Layout notes worth not re-deriving: at the 920pt window the content column is
//  920 − 224 sidebar − 28pt gutters ≈ 639, which is 3 cards of ~207. Card chrome
//  eats 94 of that (12 padding ×2 + 28 icon + 22 trailing slot + 2 gaps), so
//  **a blurb has ~112pt ≈ 18 CHARACTERS**, not "about three words" — measured
//  after three-word blurbs truncated on a real screen. `ConnectorCatalogTests`
//  asserts the character cap so copy can't quietly outgrow the card again.
//
//  A version with no card chrome at all was built and rejected: the border is
//  the hit boundary, and without it the trailing ＋ reads as floating in the
//  gutter. So every card has a border and HIERARCHY IS CARRIED BY FILL.
//
//  Out of scope on purpose — don't improvise them here: tier treatment (GW-450)
//  and the per-server drill-in (GW-451). A tier-2 card looks exactly like a
//  tier-1 card today, which is wrong and is that ticket's problem.
//

import SwiftUI

// MARK: - Card metrics

/// One place for the numbers the artboard fixes, so a card and its empty
/// trailing lane can't drift apart.
private enum ConnectorCard {
    static let corner: CGFloat = 12
    static let padding: CGFloat = 12
    static let gap: CGFloat = 10
    static let iconSize: CGFloat = 28
    static let iconCorner: CGFloat = 6
    /// Fixed, and reserved even when empty. It's what gives every card a third
    /// vertical lane that holds whether hovered or not — and it's the home
    /// GW-451's deferred "N agents" already has.
    static let trailingSlot: CGFloat = 22

    static let border = Color.white.opacity(0.10)
    static let borderHover = Color.white.opacity(0.16)
    /// Connected cards are filled; catalog cards are not. That difference IS
    /// the hierarchy — see the header note.
    static let fillConnected = Color.white.opacity(0.06)
    static let fillHover = Color.white.opacity(0.08)
    static let fillControl = Color.white.opacity(0.10)

    /// §4 doesn't cover this pane. Hover moves colour ONLY — never `transform`,
    /// which would nudge the neighbouring cards in the grid.
    static let hoverIn = Animation.easeOut(duration: 0.15)
    /// Exit ~20% faster than enter.
    static let hoverOut = Animation.easeOut(duration: 0.12)
}

/// Catalog icons carry brand hex; an entry with none falls back to the neutral
/// tile the design uses for local servers rather than inventing a colour.
extension Color {
    fileprivate init?(catalogHex: String?) {
        guard var raw = catalogHex?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8, let value = UInt32(raw, radix: 16) else {
            return nil
        }
        let hasAlpha = raw.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The ＋ is the one thing allowed to move on press (100ms, 0.97). Passing the
/// press down the environment keeps the whole card as a single hit target — the
/// border is the hit boundary — while letting only the glyph react.
private struct ConnectorCardPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var connectorCardPressed: Bool {
        get { self[ConnectorCardPressedKey.self] }
        set { self[ConnectorCardPressedKey.self] = newValue }
    }
}

private struct ConnectorCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.connectorCardPressed, configuration.isPressed)
    }
}

// MARK: - Icon tile

private struct ConnectorIconTile: View {
    let monogram: String
    /// Asset-catalog name of a bundled brand mark. nil → the monogram.
    var asset: String? = nil
    /// Template-render the mark in `foreground` (monochrome marks only).
    var tint: Bool = false
    let background: Color?
    let foreground: Color?
    let border: Color?

    /// Inset so the mark sits in the tile rather than bleeding to its corners.
    /// Wide marks (Cloudflare is 2.2:1, PostHog 5:3) scale to fit this box and
    /// letterbox vertically, which is correct — they're logotypes, not glyphs.
    private var markSize: CGFloat { ConnectorCard.iconSize - 10 }

    var body: some View {
        RoundedRectangle(cornerRadius: ConnectorCard.iconCorner, style: .continuous)
            .fill(background ?? Color.white.opacity(0.08))
            .frame(width: ConnectorCard.iconSize, height: ConnectorCard.iconSize)
            .overlay(mark)
            .overlay(
                RoundedRectangle(cornerRadius: ConnectorCard.iconCorner, style: .continuous)
                    // A near-black brand tile would otherwise vanish into the
                    // pane's black ground (Railway).
                    .strokeBorder(border ?? .clear, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// Falls back to the monogram whenever the asset is absent OR missing from
    /// the bundle — a catalog naming a logo we never shipped must not render an
    /// empty tile.
    @ViewBuilder private var mark: some View {
        if let asset, NSImage(named: asset) != nil {
            Image(asset)
                .renderingMode(tint ? .template : .original)
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .foregroundStyle(foreground ?? Color.white.opacity(0.60))
        } else {
            Text(monogram)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground ?? Color.white.opacity(0.60))
        }
    }
}

// MARK: - Card chrome

private struct ConnectorCardChrome<Content: View>: View {
    let isFilled: Bool
    let isHovered: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: ConnectorCard.gap) {
            content()
        }
        .padding(ConnectorCard.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ConnectorCard.corner, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ConnectorCard.corner, style: .continuous)
                .strokeBorder(isHovered ? ConnectorCard.borderHover : ConnectorCard.border,
                              lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: ConnectorCard.corner, style: .continuous))
    }

    private var fill: Color {
        if isHovered { return ConnectorCard.fillHover }
        return isFilled ? ConnectorCard.fillConnected : .clear
    }
}

// MARK: - Connected card

private struct ConnectedConnectorCard: View {
    let server: MCPServerConfig
    let runtime: MCPServerRuntime?
    /// The catalog entry this server came from, matched back by endpoint.
    ///
    /// Without it a card LOSES its logo the moment you connect: the grid swaps
    /// `CatalogConnectorCard` (which holds the entry) for this one (which holds
    /// only `MCPServerConfig`, and configs carry no icon), so Notion went from
    /// its mark to a letter "N" on connect. Identity must not depend on
    /// connection state.
    var icon: ConnectorIcon? = nil
    let onOpen: () -> Void

    @State private var isHovered = false

    private var severity: SettingsStateSeverity { runtime?.status.severity ?? .inert }

    var body: some View {
        Button(action: onOpen) {
            ConnectorCardChrome(isFilled: true, isHovered: isHovered) {
                ConnectorIconTile(
                    monogram: icon?.monogram ?? String(server.name.prefix(1)).uppercased(),
                    asset: icon?.asset,
                    tint: icon?.tint ?? false,
                    background: Color(catalogHex: icon?.background),
                    foreground: Color(catalogHex: icon?.foreground),
                    border: Color(catalogHex: icon?.border))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if server.transport.isLocal {
                            LocalBadge()
                        }
                    }
                    HStack(spacing: 6) {
                        if runtime?.status == .connecting {
                            ProgressView().controlSize(.small).frame(width: 8, height: 8)
                        } else {
                            SettingsStateDot(severity: severity, caption: caption)
                        }
                        Text(caption)
                            .font(.system(size: 11))
                            // §8.4: a non-default state gets its words tinted;
                            // the ordinary connected line stays secondary so the
                            // grid doesn't read as a wall of alerts.
                            .foregroundStyle(isOrdinary ? Color.secondary : severity.color)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Reserved, empty. GW-451's "which agents can use this" lands
                // here — and keeping the lane means connected and catalog cards
                // align across a row.
                Color.clear
                    .frame(width: ConnectorCard.trailingSlot, height: ConnectorCard.trailingSlot)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(hovering ? ConnectorCard.hoverIn : ConnectorCard.hoverOut) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(server.name), \(caption)")
        .accessibilityHint("Opens this server's tools")
    }

    private var isOrdinary: Bool {
        if case .connected = runtime?.status { return true }
        return runtime?.status == nil || runtime?.status == .disconnected
    }

    /// The design of record says "N of M tools". It's the ALLOWED count over the
    /// advertised one — a connected server with an empty allowlist cannot be
    /// called, so a bare "41 tools" would overclaim (GW-255).
    private var caption: String {
        switch runtime?.status {
        case .connected(let count): return "\(server.allowedTools.count) of \(count) tools"
        case .failed(let reason): return reason
        case .needsTrust: return "Not trusted"
        case .needsAuth: return "Sign in to finish"
        case .connecting: return "Connecting…"
        case .disconnected, nil: return "Not connected"
        }
    }
}

private struct LocalBadge: View {
    var body: some View {
        Text("LOCAL")
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.36)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ConnectorCard.fillControl))
            .fixedSize()
            .accessibilityLabel("Runs on this Mac")
    }
}

// MARK: - Catalog card

private struct CatalogConnectorCard: View {
    let entry: ConnectorCatalogEntry
    let isAdding: Bool
    let onAdd: () -> Void

    @State private var isHovered = false
    @Environment(\.connectorCardPressed) private var isPressed

    var body: some View {
        Button(action: onAdd) {
            ConnectorCardChrome(isFilled: false, isHovered: isHovered) {
                ConnectorIconTile(
                    monogram: entry.icon?.monogram ?? String(entry.name.prefix(1)).uppercased(),
                    asset: entry.icon?.asset,
                    tint: entry.icon?.tint ?? false,
                    background: Color(catalogHex: entry.icon?.background),
                    foreground: Color(catalogHex: entry.icon?.foreground),
                    border: Color(catalogHex: entry.icon?.border))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
        }
        .buttonStyle(ConnectorCardButtonStyle())
        .disabled(isAdding)
        .onHover { hovering in
            withAnimation(hovering ? ConnectorCard.hoverIn : ConnectorCard.hoverOut) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(entry.name), \(entry.blurb)")
        .accessibilityHint("Connects this server")
    }

    /// Persistent, never hover-only: a text "Connect" button truncated the
    /// description at 207pt, and a control that appears on hover can't be found
    /// by anyone who isn't already pointing at it.
    @ViewBuilder private var trailing: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ConnectorCard.iconCorner, style: .continuous)
                .fill(isHovered ? ConnectorCard.fillControl : .clear)
            if isAdding {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            }
        }
        .frame(width: ConnectorCard.trailingSlot, height: ConnectorCard.trailingSlot)
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}

// MARK: - Pane

struct ConnectionsCatalogView: View {
    @ObservedObject private var service = MCPClientService.shared
    @ObservedObject private var catalog = ConnectorCatalog.shared
    @ObservedObject var model: MCPPaneModel

    @State private var query = ""
    @State private var addingIDs: Set<String> = []

    /// `.adaptive` rather than three fixed columns: the window is resizable down
    /// to 640, where three 207pt cards don't fit.
    ///
    /// **200 is measured, not chosen.** At 170 a 847pt window formed three
    /// columns of 182pt, leaving 88pt of text lane — every secondary line
    /// truncated ("Not connect…", "Bases and rec…"). 200 drops to 2 columns of
    /// 278 below ~870 and still lands exactly 3×206 at the 920pt default, which
    /// is the artboard's number. Don't lower it without re-measuring the text
    /// lane: card chrome costs 94pt whatever the card width.
    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: ConnectorCard.gap, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            grid
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await catalog.refreshIfStale() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search connections", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

            addMenu
        }
    }

    /// A plain menu, NOT `Menu(primaryAction:)` — the split-button form listed
    /// "Import…" twice, once as the ＋ click and once inside its own chevron.
    private var addMenu: some View {
        Menu {
            Button("Import Servers…") { model.showingImportSheet = true }
                .disabled(!model.canImport)
            Button("Add Manually…") { model.showingAddSheet = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text("Add").font(.system(size: 12, weight: .medium))
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ConnectorCard.fillControl))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add a server")
    }

    // MARK: Grid

    @ViewBuilder private var grid: some View {
        if matchingServers.isEmpty && catalogEntries.isEmpty {
            emptyState
        } else {
            ScrollView {
                // Two grids, not one — so the break between "live" and
                // "everything else" is a real gap rather than a heading. Still
                // no section headers: the fill and the green dot already say
                // which group a card is in.
                VStack(alignment: .leading, spacing: 24) {
                    if !connectedServers.isEmpty {
                        LazyVGrid(
                            columns: columns, alignment: .leading, spacing: ConnectorCard.gap
                        ) {
                            ForEach(connectedServers) { server in
                                serverCard(server)
                            }
                        }
                    }
                    if !idleServers.isEmpty || !catalogEntries.isEmpty {
                        LazyVGrid(
                            columns: columns, alignment: .leading, spacing: ConnectorCard.gap
                        ) {
                            // Added-but-not-live first (you already chose these),
                            // then the catalog you haven't taken up yet.
                            ForEach(idleServers) { server in
                                serverCard(server)
                            }
                            ForEach(catalogEntries) { entry in
                                CatalogConnectorCard(
                                    entry: entry,
                                    isAdding: addingIDs.contains(entry.id),
                                    onAdd: { Task { await add(entry) } })
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func serverCard(_ server: MCPServerConfig) -> some View {
        ConnectedConnectorCard(
            server: server,
            runtime: service.runtime(id: server.id),
            icon: catalogIcon(for: server),
            onOpen: { model.openServerID = server.id })
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(query.isEmpty
                ? "No connectors available."
                : "Nothing matches “\(query)”.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Add manually…") { model.showingAddSheet = true }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Data

    private var matchingServers: [MCPServerConfig] {
        guard !query.isEmpty else { return service.store.servers }
        return service.store.servers.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// LIVE right now — a held session, not merely "added". This is the group
    /// that earns the top of the pane.
    private var connectedServers: [MCPServerConfig] {
        matchingServers
            .filter { service.runtime(id: $0.id)?.status.isConnected == true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Added but not live — needs auth, failed, or never connected. Ordered the
    /// same way the not-yet-added group is: catalog order first (our curated
    /// list), then everything else alphabetically.
    private var idleServers: [MCPServerConfig] {
        let rank = catalogRank
        return matchingServers
            .filter { service.runtime(id: $0.id)?.status.isConnected != true }
            .sorted { a, b in
                let ra = rank[endpointKey(a)] ?? Int.max
                let rb = rank[endpointKey(b)] ?? Int.max
                if ra != rb { return ra < rb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Position of each catalog entry, so an added server sorts by the same
    /// curated order as an un-added one.
    private var catalogRank: [String: Int] {
        var rank: [String: Int] = [:]
        for (index, entry) in catalog.entries.enumerated() {
            rank[Self.normalized(entry.endpoint)] = index
        }
        return rank
    }

    private func endpointKey(_ server: MCPServerConfig) -> String {
        guard case .http(let endpoint) = server.transport else { return server.id.uuidString }
        return Self.normalized(endpoint)
    }

    /// Matches a configured server back to the catalog entry it came from, so a
    /// connected card keeps the brand mark it had as an offer.
    private func catalogIcon(for server: MCPServerConfig) -> ConnectorIcon? {
        let key = endpointKey(server)
        return catalog.entries.first { Self.normalized($0.endpoint) == key }?.icon
    }

    /// A catalog entry you've already added is not an offer — it's the card
    /// above it. Matched on ENDPOINT, not name, so a renamed server still
    /// suppresses its catalog twin.
    private var catalogEntries: [ConnectorCatalogEntry] {
        let added = Set(service.store.servers.compactMap { server -> String? in
            guard case .http(let endpoint) = server.transport else { return nil }
            return Self.normalized(endpoint)
        })
        return catalog.entries.filter { entry in
            guard !added.contains(Self.normalized(entry.endpoint)) else { return false }
            guard !query.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(query)
                || entry.blurb.localizedCaseInsensitiveContains(query)
        }
    }

    static func normalized(_ url: URL) -> String {
        var string = url.absoluteString.lowercased()
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }

    // MARK: Actions

    /// `httpAuth` stays nil — that IS the tier-1 path. The swift-sdk performs
    /// dynamic client registration, so there is no per-connector auth code and
    /// nothing here to configure.
    @MainActor
    private func add(_ entry: ConnectorCatalogEntry) async {
        guard !addingIDs.contains(entry.id) else { return }
        addingIDs.insert(entry.id)
        defer { addingIDs.remove(entry.id) }

        let config = MCPServerConfig(
            id: UUID(), name: entry.name, transport: .http(endpoint: entry.endpoint))
        service.addServer(config)
        await service.connectInteractively(id: config.id)
    }
}

