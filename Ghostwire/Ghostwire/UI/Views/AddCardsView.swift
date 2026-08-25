//
//  AddCardsView.swift
//  Ghostwire
//
//  GW-466. The Feed side of MCP tool binding — the replacement for the controls
//  GW-449 removed from the server drill-in. Card-first by design (Keelan,
//  2026-08-22): you judge a card by seeing it, so the Add page renders each
//  candidate tool as the real card it would become, with your real data, and
//  one click adds it. No toggles, no server states, no arguments UI — a tool
//  that requires input is a question, not a standing value (GW-214), and it
//  simply doesn't appear here.
//
//  Eligibility = the shipped candidacy rule ∧ the allowlist: `isFeedCandidate`
//  (read-only-hinted, not destructive, ZERO required inputs) AND allowed in
//  Connections. Previews go through `callAllowedTool`, the same single choke
//  point the feed polls through — this page can never call anything the
//  allowlist wouldn't.
//

import SwiftUI

// MARK: - Cards tab container (root ↔ Add page)

/// The window's Cards tab: header, grid, a floating ＋, and the Add-cards page
/// it opens. Root ↔ add is the same drill-in idiom as Connections' root ↔
/// server (§8.6 — write-through state, so a drill-in, never a sheet).
struct FeedPaneView: View {
    @State private var showAddCards = false

    var body: some View {
        VStack(spacing: 0) {
            if showAddCards {
                WindowPaneHeader(title: "Add cards", onBack: { showAddCards = false })
                AddCardsView()
            } else {
                WindowPaneHeader(title: "Cards")
                FeedSurfaceView(onAddCards: { showAddCards = true })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !showAddCards { addButton }
        }
        // emil: page swap is occasional → a fast crossfade, no travel.
        .animation(.easeOut(duration: 0.15), value: showAddCards)
    }

    private var addButton: some View {
        Button {
            showAddCards = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.95), in: Circle())
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(24)
        .help("Add cards")
        .accessibilityLabel("Add cards")
    }
}

// MARK: - Section model (pure, tested)

/// One server's gallery section. Pure construction from config + runtime so
/// eligibility is testable without a live server.
struct AddCardsSection: Identifiable, Equatable {
    let serverID: UUID
    let serverName: String
    /// Allowed feed candidates, stable order. Never empty — a server with no
    /// eligible tools has no section (and a disconnected server can't list
    /// tools at all, so it has no section either; Connections owns that state).
    let tools: [MCPToolInfo]
    let boundTools: Set<String>

    var id: UUID { serverID }

    nonisolated static func build(
        servers: [MCPServerConfig], runtimes: [UUID: MCPServerRuntime]
    ) -> [AddCardsSection] {
        servers.filter(\.isEnabled).compactMap { config in
            guard let runtime = runtimes[config.id], runtime.status.isConnected else {
                return nil
            }
            let tools =
                runtime.tools
                .filter { config.allowedTools.contains($0.name) && $0.isFeedCandidate }
                .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
            guard !tools.isEmpty else { return nil }
            return AddCardsSection(
                serverID: config.id,
                serverName: config.name,
                tools: tools,
                boundTools: Set(config.feedBindings.map(\.tool))
            )
        }
    }
}

// MARK: - Add page

struct AddCardsView: View {
    @ObservedObject private var service = MCPClientService.shared
    /// cardId → rendered preview. Absent = still loading (skeleton).
    @State private var previews: [String: FeedCard] = [:]
    /// Tools whose preview call failed — shown as a quiet unavailable cell
    /// rather than vanishing mid-scroll.
    @State private var failed: Set<String> = []

    private let columns = [
        GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 12, alignment: .top)
    ]

    private var sections: [AddCardsSection] {
        AddCardsSection.build(servers: service.store.servers, runtimes: service.runtimes)
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keyed on the section signature, not run-once: a server that connects
        // or gets a tool allowed AFTER the page opened re-fires the load, so a
        // late section gets previews instead of permanent skeletons — and each
        // re-fire clears `failed`, which is also the retry path for a
        // transient preview failure.
        .task(id: sectionsKey) { await loadPreviews() }
    }

    private var sectionsKey: String {
        sections.map { section in
            "\(section.serverID.uuidString):\(section.tools.map(\.name).joined(separator: ","))"
        }.joined(separator: "|")
    }

    // §8.3: the empty state says what the page is FOR, not that it's empty.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(
                "Allow a read-only tool on a connected server in Connections — "
                    + "anything that can answer without input shows up here as a card."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionView(_ section: AddCardsSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.serverName)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.66)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(section.tools) { tool in
                    cell(section: section, tool: tool)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(section: AddCardsSection, tool: MCPToolInfo) -> some View {
        let cardId = Self.cardId(serverID: section.serverID, tool: tool.name)
        let isBound = section.boundTools.contains(tool.name)
        ZStack(alignment: isBound ? .topTrailing : .bottomTrailing) {
            if let card = previews[cardId] {
                FeedCardView(card: card)
            } else {
                placeholder(
                    title: tool.displayTitle, unavailable: failed.contains(cardId))
            }
            if isBound {
                boundMenu(section: section, tool: tool)
            } else if previews[cardId] != nil {
                addPill(section: section, tool: tool)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(section.serverName), \(tool.displayTitle), \(isBound ? "in your feed" : "available")"
        )
    }

    /// The one primary affordance: a white ＋ that adds the card. Everything on
    /// this page is write-through — no Save, no confirm.
    private func addPill(section: AddCardsSection, tool: MCPToolInfo) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                setBound(true, section: section, tool: tool)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.95), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Add to your feed")
        .accessibilityLabel("Add \(tool.displayTitle)")
    }

    /// Active cards get the secondary affordance: a bare ⋮ opening the card
    /// menu — settings on top, red Remove at the bottom (Keelan's V4 spec).
    private func boundMenu(section: AddCardsSection, tool: MCPToolInfo) -> some View {
        Menu {
            Button("Card Settings…") {
                GhostwireWindowModel.shared.showSettings(.modules)
            }
            Divider()
            Button("Remove Card", role: .destructive) {
                withAnimation(.easeOut(duration: 0.2)) {
                    setBound(false, section: section, tool: tool)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(8)
        .help("Card options")
        .accessibilityLabel("Options for \(tool.displayTitle)")
    }

    /// Skeleton while the preview call is in flight; a quiet "no preview" once
    /// it has failed. Same frame as the card it stands in for.
    private func placeholder(title: String, unavailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if unavailable {
                Text("No preview — the tool didn't answer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.08))
                        .frame(width: 120, height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.08))
                        .frame(width: 88, height: 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: UnifiedCardView.cardWidth, height: UnifiedCardView.cardHeight, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(white: 0.2), lineWidth: 1)
        )
    }

    // MARK: Actions & loading

    static func cardId(serverID: UUID, tool: String) -> String {
        MCPFeedSource.cardId(serverID: serverID, tool: tool)
    }

    private func setBound(_ bound: Bool, section: AddCardsSection, tool: MCPToolInfo) {
        service.setFeedTool(serverID: section.serverID, tool: tool.name, bound: bound)
        if !bound {
            // Removal must not wait on the next successful publish — with the
            // surviving sources failing, that can be arbitrarily far away.
            FeedCardStore.shared.drop(id: Self.cardId(serverID: section.serverID, tool: tool.name))
        }
        // Same immediacy idiom as Connections' setAllowed: the debounced
        // feedConfigDidChange subscription would get there, but the card should
        // appear/disappear with the click, not at the next poll.
        FeedSourceCoordinator.shared.start()
    }

    /// One preview call per candidate, through the allowlist choke point.
    /// Bound tools reuse their live card instead of spending a second call.
    /// Currently serial across servers too — GW-471 owns fanning the
    /// independent server lanes out into a task group.
    private func loadPreviews() async {
        failed.removeAll()
        // Nothing connects servers at launch (GW-214); without this the page
        // would open empty until the user visited Connections. Opening the
        // page is a user gesture, so connecting here mirrors Connections'
        // "Test" — non-interactive (needsAuth lands as no section), and
        // NEVER while a connect is already in flight: `connect` has no
        // re-entry guard of its own, and racing it can strand the losing
        // stdio subprocess (the same hazard MCPFeedSource's
        // `.connectInFlight` throw exists for).
        for config in service.store.servers where config.isEnabled {
            guard !Task.isCancelled else { return }
            let status = service.runtime(id: config.id)?.status ?? .disconnected
            if case .connecting = status { continue }
            if !status.isConnected {
                await service.connect(id: config.id)
            }
        }
        for section in sections {
            for tool in section.tools {
                // The page can be left mid-fan-out; without this check the
                // loop would keep spending real calls against billing-backed
                // APIs for a view that no longer exists.
                guard !Task.isCancelled else { return }
                let cardId = Self.cardId(serverID: section.serverID, tool: tool.name)
                guard previews[cardId] == nil else { continue }
                if let live = FeedCardStore.shared.orderedCards.first(where: { $0.id == cardId }) {
                    previews[cardId] = live
                    continue
                }
                guard
                    let output = try? await service.callAllowedTool(
                        serverID: section.serverID, name: tool.name, arguments: [:])
                else {
                    if !Task.isCancelled { failed.insert(cardId) }
                    continue
                }
                previews[cardId] = MCPFeedCardMapper.card(
                    from: output,
                    tool: tool.name,
                    serverName: section.serverName,
                    id: cardId,
                    sourceId: MCPFeedSource.sourceId(serverID: section.serverID),
                    now: Date()
                )
            }
        }
    }
}
