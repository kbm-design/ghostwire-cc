//
//  ShelfWindowModel.swift
//  Ghostwire
//
//  GW-223. Window-local view state for the detached Shelf window: search text,
//  active section, and selection. Deliberately SEPARATE from the in-notch
//  `UnifiedShelfViewModel` selection/filter so typing or selecting in the window
//  doesn't reach into the notch (Keelan's call, 06-13). The card FEED and every
//  mutating action (pin/copy/send/paste/delete) still come from the shared
//  `UnifiedShelfViewModel.shared` — this only layers a window-scoped lens on top.
//

import Foundation

@MainActor
final class ShelfWindowModel: ObservableObject {
    /// Light section scaffold (GW-223). The full filters/views engine is GW-220;
    /// here we only split the existing feed by what each card already knows about
    /// itself — pinned (saved) vs. history (transient) — plus an "all" passthrough.
    enum Section: String, CaseIterable, Identifiable {
        case all, pinned, history

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .pinned: return "Pinned"
            case .history: return "History"
            }
        }

        var systemImage: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .pinned: return "pin"
            case .history: return "clock"
            }
        }
    }

    @Published var searchText: String = ""
    @Published var section: Section = .all
    /// Selected card id — stable across recompute, unlike an index (mirrors the
    /// in-notch row's GW-213 selection model, but window-scoped).
    @Published var selectedID: String?
    /// Bumped to pull keyboard focus onto the grid (e.g. after a click-select),
    /// since a card can't reach the grid's `@FocusState` directly.
    @Published var focusRequest: Int = 0

    /// The shared feed narrowed by the active section, then the search query.
    /// Feed order (newest-first) is preserved.
    func visibleCards(from cards: [UnifiedCard]) -> [UnifiedCard] {
        cards.filter { card in
            switch section {
            case .all: break
            case .pinned: if !card.isPinned { return false }
            case .history: if card.isPinned { return false }
            }
            return UnifiedShelfViewModel.matches(card, query: searchText)
        }
    }

    // MARK: - Selection / keyboard nav

    /// Move selection by `delta` within the visible list (clamped). `delta` is ±1
    /// for left/right and ±columnCount for up/down so arrows feel grid-native.
    /// Seeds the first card when nothing is selected yet.
    func moveSelection(by delta: Int, in list: [UnifiedCard]) {
        guard !list.isEmpty else { selectedID = nil; return }
        let current = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(list.count - 1, current + delta))
        selectedID = list[next].id
    }

    /// Click-select a card and pull keyboard focus to the grid so arrows / type /
    /// ↩ take over from the mouse.
    func select(_ card: UnifiedCard) {
        selectedID = card.id
        focusRequest += 1
    }

    /// Drop a selection that's no longer visible (after a section/search change).
    func pruneSelection(against list: [UnifiedCard]) {
        if let id = selectedID, !list.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    var selectedCard: UnifiedCard? {
        guard let selectedID else { return nil }
        // Resolved against the shared feed so actions hit the right store.
        return UnifiedShelfViewModel.shared.cards.first { $0.id == selectedID }
    }
}
