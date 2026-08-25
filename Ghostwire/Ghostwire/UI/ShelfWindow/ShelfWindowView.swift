//
//  ShelfWindowView.swift
//  Ghostwire
//
//  GW-223. The detached Shelf's content: a search field + light section tabs
//  (All / Pinned / History) over a multi-column LazyVGrid of the SAME
//  `UnifiedCardView` used in the notch — no second card renderer. The cards keep
//  their exact size and interactions (hover paste/copy/send, right-click menu,
//  double-click, send-to-agent); the window just gives them room to breathe and
//  a real search + keyboard grid-nav.
//
//  State boundary (GW-223): the card FEED and every mutating action come from the
//  shared `UnifiedShelfViewModel.shared`; search / section / selection are
//  window-local (`ShelfWindowModel`) so they don't reach into the notch.
//

import AppKit
import SwiftUI

struct ShelfWindowView: View {
    @ObservedObject private var feed = UnifiedShelfViewModel.shared
    @StateObject private var model = ShelfWindowModel()

    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    private let cardWidth = UnifiedCardView.cardWidth
    private let gutter: CGFloat = 18
    private let margin: CGFloat = 24

    var body: some View {
        let cards = feed.cards
        let visible = model.visibleCards(from: cards)

        VStack(spacing: 0) {
            header(visibleCount: visible.count)
            Divider().overlay(Color.white.opacity(0.08))
            content(cards: cards, visible: visible)
        }
        // Canvas (solid black) is owned by the window root (GhostwireWindowView).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drop a stale selection when the section/search change hides it.
        .onChange(of: model.section) { model.pruneSelection(against: model.visibleCards(from: feed.cards)) }
        .onChange(of: model.searchText) { model.pruneSelection(against: model.visibleCards(from: feed.cards)) }
        // A click-select (or type-dive) pulls keyboard focus onto the grid.
        .onChange(of: model.focusRequest) { gridFocused = true }
        // Land in the search field so you can start narrowing immediately.
        .onAppear { searchFocused = true }
    }

    // MARK: - Header

    private func header(visibleCount: Int) -> some View {
        HStack(spacing: 14) {
            searchField
            sectionPicker
            Spacer(minLength: 8)
            Text("\(visibleCount)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        // Clear the transparent titlebar / traffic-light row.
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search shelf", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                // ↓ or ↩ from the search field dives into the grid (selecting the
                // first card) rather than acting — actions need a grid selection.
                .onKeyPress(.downArrow) { diveIntoGrid(); return .handled }
                .onKeyPress(.return) { diveIntoGrid(); return .handled }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            searchFocused ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    private var sectionPicker: some View {
        Picker("", selection: $model.section) {
            ForEach(ShelfWindowModel.Section.allCases) { section in
                Text(section.label).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private func content(cards: [UnifiedCard], visible: [UnifiedCard]) -> some View {
        if cards.isEmpty {
            emptyState
        } else if visible.isEmpty {
            noMatchesState
        } else {
            grid(visible)
        }
    }

    private func grid(_ visible: [UnifiedCard]) -> some View {
        GeometryReader { geo in
            let columns = columnCount(forWidth: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: gridItems(columns), alignment: .leading, spacing: gutter) {
                        ForEach(visible) { card in
                            UnifiedCardView(
                                card: card,
                                isSelected: card.id == model.selectedID,
                                onSelect: { model.select($0) },
                                showsPasteAction: false
                            )
                            .id(card.id)
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handleGridKey($0, columns: columns, visible: visible) }
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Nothing on the shelf yet")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Copies land here automatically. Pin anything to keep it.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.section == .pinned ? "pin.slash" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(noMatchesText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesText: String {
        if !model.searchText.isEmpty { return "No cards match “\(model.searchText)”" }
        switch model.section {
        case .pinned: return "No pinned cards yet"
        case .history: return "No clipboard history yet"
        case .all: return "Nothing here"
        }
    }

    // MARK: - Grid metrics

    private func columnCount(forWidth width: CGFloat) -> Int {
        let usable = width - 2 * margin + gutter
        return max(1, Int(usable / (cardWidth + gutter)))
    }

    private func gridItems(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(cardWidth), spacing: gutter, alignment: .top), count: count)
    }

    // MARK: - Keyboard

    /// Move focus from the search field into the grid, seeding a selection.
    private func diveIntoGrid() {
        let visible = model.visibleCards(from: feed.cards)
        guard !visible.isEmpty else { return }
        if model.selectedID == nil || !visible.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = visible.first?.id
        }
        searchFocused = false
        gridFocused = true
    }

    private func handleGridKey(_ press: KeyPress, columns: Int, visible: [UnifiedCard]) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            model.moveSelection(by: -1, in: visible); return .handled
        case .rightArrow:
            model.moveSelection(by: 1, in: visible); return .handled
        case .upArrow:
            model.moveSelection(by: -columns, in: visible); return .handled
        case .downArrow:
            model.moveSelection(by: columns, in: visible); return .handled
        case .return:
            guard let card = model.selectedCard else { return .ignored }
            if press.modifiers.contains(.command) {
                Task { await UnifiedShelfViewModel.shared.copy(card) }
            } else {
                Task { await UnifiedShelfViewModel.shared.send(card) }
            }
            return .handled
        case .escape:
            if !model.searchText.isEmpty { model.searchText = "" } else { gridFocused = false }
            return .handled
        default:
            // Type-to-search: a printable char hops to the search field and seeds
            // it, mirroring the notch row's type-to-filter.
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  let ch = press.characters.first,
                  press.characters.count == 1,
                  ch == " " || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol
            else { return .ignored }
            model.searchText.append(press.characters)
            searchFocused = true
            return .handled
        }
    }
}
