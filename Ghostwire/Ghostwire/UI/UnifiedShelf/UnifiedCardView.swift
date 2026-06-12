//
//  UnifiedCardView.swift
//  Ghostwire
//
//  GW-218. One card in the unified feed. Chrome (pin marker, source-app glyph,
//  relative time, hover actions, right-click menu) + a type-aware preview that
//  dispatches on `CardKind` via `UnifiedCardContent` — modeled on the
//  `ToolResultViews` dispatcher idiom, not a parallel one.
//
//  Hover reveals exactly three actions — Paste / Copy / Send — per Keelan's
//  spec. Pin (promote) and Delete live in the right-click menu, not on the card.
//

import AppKit
import SwiftUI

struct UnifiedCardView: View {
    let card: UnifiedCard
    /// Driven by GW-213 keyboard nav (commit 2); mouse hover also highlights.
    var isSelected: Bool = false

    @ObservedObject private var vm = UnifiedShelfViewModel.shared
    @State private var isHovered = false
    @State private var copied = false
    @State private var pasteState: ActionFeedback = .idle
    @State private var sendState: ActionFeedback = .idle

    private enum ActionFeedback { case idle, ok, fail }

    static let cardWidth: CGFloat = 152
    static let cardHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            footer
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.10 : (isHovered ? 0.07 : 0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .overlay(alignment: .topTrailing) { if card.isPinned { pinMarker } }
        .overlay(alignment: .bottomTrailing) { if isHovered { hoverActions } }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu { contextMenu }
        .help(card.previewText)
    }

    // MARK: - Preview + footer

    private var preview: some View {
        UnifiedCardContent(card: card)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            sourceGlyph
                .frame(width: 12, height: 12)

            if let date = card.date {
                Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if card.isPinned {
                Text("Saved")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if card.isTruncatedText {
                Text("trimmed")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        // Hidden under the hover action bar; keeps layout stable.
        .opacity(isHovered ? 0 : 1)
    }

    private var pinMarker: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(5)
    }

    /// Source-app icon (transient capture), else the kind glyph.
    private var sourceGlyph: some View {
        Group {
            if let icon = Self.appIcon(for: card.sourceBundleId) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: kindSymbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var kindSymbol: String {
        switch card.kind {
        case .text: return "text.alignleft"
        case .color: return "paintpalette"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    // MARK: - Hover actions (exactly three)

    private var hoverActions: some View {
        HStack(spacing: 8) {
            actionButton(systemName: pasteGlyph, tint: feedbackTint(pasteState), help: "Paste into current field") {
                Task {
                    let ok = await vm.paste(card)
                    flash($pasteState, ok ? .ok : .fail)
                }
            }
            actionButton(systemName: copied ? "checkmark" : "doc.on.doc", tint: copied ? TerminalColors.green : .secondary, help: "Copy") {
                vm.copy(card)
                flashCopied()
            }
            actionButton(systemName: sendGlyph, tint: feedbackTint(sendState), help: "Send to agent") {
                Task {
                    let result = await vm.send(card)
                    switch result {
                    case .delivered: flash($sendState, .ok)
                    case .failed: flash($sendState, .fail)
                    case .awaitingPick: break // picker carries the outcome
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(6)
    }

    private func actionButton(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var pasteGlyph: String {
        switch pasteState {
        case .idle: return "doc.on.clipboard"
        case .ok: return "checkmark"
        case .fail: return "exclamationmark.triangle"
        }
    }

    private var sendGlyph: String {
        switch sendState {
        case .idle: return "terminal"
        case .ok: return "checkmark"
        case .fail: return "terminal.fill"
        }
    }

    private func feedbackTint(_ s: ActionFeedback) -> Color {
        switch s {
        case .idle: return .secondary
        case .ok: return TerminalColors.green
        case .fail: return TerminalColors.amber
        }
    }

    // MARK: - Right-click menu (Pin / Delete + a couple of obvious extras)

    @ViewBuilder
    private var contextMenu: some View {
        if !card.isPinned {
            Button { vm.pin(card) } label: { Label("Pin", systemImage: "pin") }
        }
        Button { vm.copy(card); flashCopied() } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { Task { await vm.send(card) } } label: { Label("Send to Agent", systemImage: "terminal") }
        if let url = card.fileURL {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) { vm.delete(card) } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Feedback timers

    private func flashCopied() {
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation { copied = false } }
        }
    }

    private func flash(_ binding: Binding<ActionFeedback>, _ state: ActionFeedback) {
        withAnimation { binding.wrappedValue = state }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation { binding.wrappedValue = .idle } }
        }
    }

    // MARK: - Statics

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func appIcon(for bundleId: String?) -> NSImage? {
        guard let bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Per-type content dispatcher (modeled on ToolResultContent)

struct UnifiedCardContent: View {
    let card: UnifiedCard

    var body: some View {
        switch card.kind {
        case .text:  TextCardContent(card: card)
        case .color: ColorCardContent(card: card)
        case .link:  LinkCardContent(card: card)
        case .image: ImageCardContent(card: card)
        case .file:  FileCardContent(card: card)
        }
    }
}

private struct TextCardContent: View {
    let card: UnifiedCard

    private var body3: String {
        card.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mono for things that look like code/paths (cheap heuristic, preview only).
    private var usesMono: Bool {
        let s = body3
        return s.contains("/") || s.contains("{") || s.contains(";") || s.contains("()") || s.contains("=>")
    }

    var body: some View {
        Text(body3.isEmpty ? "(empty)" : body3)
            .font(usesMono ? .system(size: 11, design: .monospaced) : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ColorCardContent: View {
    let card: UnifiedCard

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: card.color ?? .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
            Text(card.colorHex ?? "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LinkCardContent: View {
    let card: UnifiedCard

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Text(card.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageCardContent: View {
    let card: UnifiedCard
    @State private var thumbnail: NSImage?
    @State private var sizeText: String?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(card.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        guard let url = card.fileURL else { return }
        sizeText = FileSizeFormatter.string(for: url)
        if let image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 80, height: 80)) {
            thumbnail = image
        }
    }
}

private struct FileCardContent: View {
    let card: UnifiedCard
    @State private var sizeText: String?

    private var icon: NSImage? {
        guard let url = card.fileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.tertiary) }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let sizeText {
                    Text(sizeText).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if let url = card.fileURL { sizeText = FileSizeFormatter.string(for: url) }
        }
    }
}

// MARK: - File size helper

enum FileSizeFormatter {
    static func string(for url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
