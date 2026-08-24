//
//  FeedSurfaceView.swift
//  Ghostwire
//
//  GW-259. The two presentations of the Dashboard feed, both reading the shared
//  FeedCardStore:
//    • notch  → a compact horizontal row of the top-N cards (its own notch tab).
//    • window → a multi-column grid of all cards (3–4 across), no media controls.
//  The surface is chosen by the `ghostwireSurface` environment flag (GW-223).
//
//  GW-466/GW-290: the window grid now drag-reorders (live in memory while the
//  drag hovers, persisted once on drop) and MCP-backed cards carry a context
//  menu (Card Settings… / Remove Card). The persisted order is what the
//  notch's top-N candidate set comes FROM — but the notch row renders
//  `FeedRankingController.notchCards`, so under any ranking mode but `.fixed`
//  an escalation can override a fresh drag. The notch row stays read-only.
//

import SwiftUI
import UniformTypeIdentifiers

/// Picks the right feed presentation for the current surface.
struct FeedSurfaceView: View {
    @Environment(\.ghostwireSurface) private var surface
    /// Window-only: opens the Add-cards page (GW-466). The notch row never
    /// shows an add affordance — quick-view space is sacred.
    var onAddCards: (() -> Void)? = nil

    var body: some View {
        Group {
            if surface == .window {
                FeedGridView(onAddCards: onAddCards)
            } else {
                FeedCardRowView()
            }
        }
        // GW-182: "seen" belongs to the feed actually being drawn, not to the
        // notch opening. The notch's `open()` fires for every tab, so marking
        // novelty there cleared cards the user never looked at. Re-ranks against
        // current context first, then records the view.
        .onAppear { FeedRankingController.shared.surfaceDidOpen() }
    }
}

// MARK: - Notch: compact horizontal top-N row

struct FeedCardRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // GW-182: the notch row reads the RANKED top-N, not the store's raw prefix.
    // The controller falls back to the store's order whenever ranking has no
    // confident opinion, so this is the same thing on a quiet machine.
    private let ranking = FeedRankingController.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ranking.notchCards) { card in
                    FeedCardView(card: card, isStale: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reshuffle: animate position changes when the order changes — unless
        // the user prefers reduced motion.
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: ranking.notchCards.map(\.id))
    }
}

// MARK: - Window: multi-column card grid (3–4 across)

struct FeedGridView: View {
    var onAddCards: (() -> Void)? = nil

    private let store = FeedCardStore.shared
    private let service = MCPClientService.shared
    @State private var draggingID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Adaptive so the column count tracks the window width: each cell is one
    // FeedCardView (176pt wide) → ~3–4 across in the detached window.
    private let columns = [GridItem(.adaptive(minimum: 176, maximum: 220), spacing: 12, alignment: .top)]

    var body: some View {
        Group {
            if store.orderedCards.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.orderedCards) { card in
                    cell(for: card)
                }
            }
            .padding(20)
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                value: store.orderedCards.map(\.id))
        }
        // A drag released over the padding, the header, or outside any cell
        // never reaches a cell delegate's performDrop — without this
        // container-level catch the dragged card would stay ghosted at 40%.
        .onDrop(
            of: [UTType.text],
            delegate: FeedGridEndDropDelegate(draggingID: $draggingID, store: store))
    }

    @ViewBuilder
    private func cell(for card: FeedCard) -> some View {
        FeedCardView(card: card)
            .contextMenu { contextMenu(for: card) }
            .opacity(draggingID == card.id ? 0.4 : 1)
            .onDrag {
                draggingID = card.id
                return NSItemProvider(object: card.id as NSString)
            }
            .onDrop(
                of: [UTType.text],
                delegate: FeedCardDropDelegate(
                    cardID: card.id, draggingID: $draggingID, store: store))
    }

    /// Right-click on an MCP-backed card manages its binding in place (GW-466):
    /// settings on top, red Remove at the bottom. Cards from built-in sources
    /// get no menu — their catalog lives in Settings › Feed.
    @ViewBuilder
    private func contextMenu(for card: FeedCard) -> some View {
        if let binding = mcpBinding(for: card) {
            Button("Card Settings…") {
                GhostwireWindowModel.shared.showSettings(.modules)
            }
            Divider()
            Button("Remove Card", role: .destructive) {
                service.setFeedTool(serverID: binding.serverID, tool: binding.tool, bound: false)
                // Immediate: the next successful publish would drop it anyway,
                // but that can be arbitrarily far away when other sources fail.
                store.drop(id: card.id)
                FeedSourceCoordinator.shared.start()
            }
        }
    }

    /// The card's binding, recovered from its id — only when that binding
    /// actually exists. The server-wide attention card can't reach this at
    /// all: its id uses `#server`, which `parseCardId` rejects.
    private func mcpBinding(for card: FeedCard) -> (serverID: UUID, tool: String)? {
        guard let parsed = MCPFeedSource.parseCardId(card.id),
              let config = service.store.servers.first(where: { $0.id == parsed.serverID }),
              config.feedBindings.contains(where: { $0.tool == parsed.tool })
        else { return nil }
        return parsed
    }

    // §8.3: state the surface's job, not its emptiness.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Cards keep your own numbers in view — prices, issues, builds — without opening anything.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let onAddCards {
                Button("Add cards", action: onAddCards)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Drag-reorder (GW-290)

/// Live-reorders while the drag hovers (the standard LazyVGrid idiom — grids
/// have no native `onMove`). Hover swaps are in-memory only (`reorderLive`) so
/// a drag that never lands commits nothing and each crossing costs no
/// Defaults write; the order persists exactly once, on drop (`commitOrder`).
private struct FeedCardDropDelegate: DropDelegate {
    let cardID: String
    @Binding var draggingID: String?
    let store: FeedCardStore

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != cardID,
              let from = store.orderedCards.firstIndex(where: { $0.id == draggingID }),
              let to = store.orderedCards.firstIndex(where: { $0.id == cardID })
        else { return }
        store.reorderLive(
            fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.commitOrder()
        draggingID = nil
        return true
    }
}

/// Catches a drag released anywhere in the grid that isn't a card cell.
/// Committing here too keeps "I dropped it, it stays where it is" true no
/// matter which delegate the release lands on.
private struct FeedGridEndDropDelegate: DropDelegate {
    @Binding var draggingID: String?
    let store: FeedCardStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingID != nil else { return false }
        store.commitOrder()
        draggingID = nil
        return true
    }
}
