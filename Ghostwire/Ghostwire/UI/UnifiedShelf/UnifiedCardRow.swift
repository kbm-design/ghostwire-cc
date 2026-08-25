//
//  UnifiedCardRow.swift
//  Ghostwire
//
//  GW-218. The unified surface: ONE horizontal, scrollable feed of cards over
//  both stores (saved/pinned + transient copies). Copy is the primary way in;
//  drag is demoted to a thin "or drag here" affordance at the trailing edge
//  (kept for multi-file gestures, no-file content, and not clobbering the
//  pasteboard). Drops land in the Shelf (saved) — a deliberate "keep this".
//
//  Replaces the old "Drop files here" hero + the separate clipboard swap-view.
//
//  GW-213: the same row is the full-keyboard surface. The openClipboardHistory
//  hotkey focuses it; arrows move selection, type-to-filter narrows, ↩ sends to
//  the agent (staged), ⌘↩ re-copies, esc clears the filter then drops focus.
//  Keyboard works because the notch panel is key-capable (canBecomeKey) — the
//  same reason the chat TextField receives input.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct UnifiedCardRow: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var model = UnifiedShelfViewModel.shared
    @ObservedObject private var coordinator = GhostwireViewCoordinator.shared
    @FocusState private var rowFocused: Bool

    private let spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.filterText.isEmpty { filterBar }

            Group {
                if model.isEmpty {
                    emptyState
                } else {
                    populated
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: dropTypes, isTargeted: $vm.dragDetectorTargeting) { providers in
            handleDrop(providers: providers)
        }
        .focusable(!model.isEmpty)
        .focused($rowFocused)
        // The selected card's accent outline is the focus indicator; suppress the
        // system focus ring that would otherwise outline the whole row.
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handleKey($0) }
        // The openClipboardHistory hotkey lands here: grab keyboard focus and
        // seed a selection so arrows work immediately. We only auto-focus on the
        // explicit hotkey, never on a normal open (so we don't steal chat focus).
        .onAppear { consumeClipboardRequest() }
        .onChange(of: coordinator.requestClipboardHistory) { consumeClipboardRequest() }
        .onChange(of: model.filterText) { model.selectFirstIfNeeded() }
        // A click-select (or any focus request) pulls keyboard focus to the row.
        .onChange(of: model.focusRequest) { rowFocused = true }
    }

    private var populated: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(model.filteredCards) { card in
                        UnifiedCardView(card: card, isSelected: card.id == model.selectedID)
                            .id(card.id)
                    }
                    dragAffordance
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(model.filterText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(model.filteredCards.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button { model.filterText = "" } label: {
                Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear filter (esc)")
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Keyboard (GW-213)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow, .upArrow:
            model.moveSelection(-1); return .handled
        case .rightArrow, .downArrow:
            model.moveSelection(1); return .handled
        case .return:
            guard let card = model.selectedCard else { return .ignored }
            if press.modifiers.contains(.command) {
                Task { await model.copy(card) }
            } else {
                Task { await model.send(card) }
            }
            return .handled
        case .escape:
            if !model.filterText.isEmpty { model.filterText = "" } else { rowFocused = false }
            return .handled
        case .delete: // backspace
            if !model.filterText.isEmpty { model.filterText.removeLast(); return .handled }
            return .ignored
        default:
            // Type-to-filter: accept a printable character, ignore chorded keys.
            guard !press.modifiers.contains(.command),
                  !press.modifiers.contains(.control),
                  let ch = press.characters.first,
                  press.characters.count == 1,
                  ch == " " || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol
            else { return .ignored }
            model.filterText.append(press.characters)
            return .handled
        }
    }

    private func consumeClipboardRequest() {
        guard coordinator.requestClipboardHistory else { return }
        coordinator.requestClipboardHistory = false
        model.selectFirstIfNeeded()
        rowFocused = true
    }

    /// Thin trailing "or drag here" target — the demoted drop hero.
    private var dragAffordance: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Text("or drag\nhere")
                .font(.system(size: 9))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 64, height: UnifiedCardView.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    vm.dragDetectorTargeting ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4])
                )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Copy or drag to start")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(clipboardEnabled
                 ? "Copies land here automatically. Pin anything to keep it."
                 : "Drag items in, or turn on clipboard capture in Settings.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: UnifiedCardView.cardHeight + 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    vm.dragDetectorTargeting ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
        )
    }

    private var clipboardEnabled: Bool {
        Defaults[.clipboardHistoryEnabled]
    }

    private var dropTypes: [UTType] {
        [.fileURL, .url, .utf8PlainText, .plainText, .data]
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !ShelfSelectionModel.shared.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
}
