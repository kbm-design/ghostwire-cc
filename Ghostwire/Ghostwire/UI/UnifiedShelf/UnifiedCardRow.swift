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

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct UnifiedCardRow: View {
    @EnvironmentObject var vm: GhostwireViewModel
    @ObservedObject private var model = UnifiedShelfViewModel.shared

    private let spacing: CGFloat = 8

    var body: some View {
        Group {
            if model.isEmpty {
                emptyState
            } else {
                populated
            }
        }
        .frame(maxWidth: .infinity)
        .onDrop(of: dropTypes, isTargeted: $vm.dragDetectorTargeting) { providers in
            handleDrop(providers: providers)
        }
    }

    private var populated: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(model.cards) { card in
                    UnifiedCardView(card: card)
                }
                dragAffordance
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
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
