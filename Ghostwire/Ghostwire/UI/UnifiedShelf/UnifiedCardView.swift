//
//  UnifiedCardView.swift
//  Ghostwire
//
//  GW-218. One card in the unified feed. A type-aware preview dispatched on
//  `CardKind` via `UnifiedCardContent` (modeled on the `ToolResultViews`
//  dispatcher idiom), plus chrome: pin marker, hover actions, right-click menu.
//
//  Image/color cards are FLUSH — the visual fills the card edge-to-edge with the
//  filename/hex + source-app glyph + time overlaid on a bottom scrim (Supaste
//  idiom, reimplemented clean). Text/link/file cards are padded with the footer
//  below. Hover reveals exactly three actions — Paste / Copy / Send — top-right,
//  so they don't fight the bottom info. Pin + Delete live in the right-click menu.
//

import AppKit
import Defaults
import SwiftUI

struct UnifiedCardView: View {
    let card: UnifiedCard
    /// Driven by GW-213 keyboard nav; mouse hover also highlights.
    var isSelected: Bool = false

    @ObservedObject private var vm = UnifiedShelfViewModel.shared
    @State private var isHovered = false
    @State private var copied = false
    @State private var pasteState: ActionFeedback = .idle
    @State private var sendState: ActionFeedback = .idle

    private enum ActionFeedback { case idle, ok, fail }

    static let cardWidth: CGFloat = 176
    static let cardHeight: CGFloat = 110
    private static let corner: CGFloat = 12

    var body: some View {
        UnifiedCardContent(card: card)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .overlay(alignment: .topLeading) { if card.isPinned { pinMarker } }
            .overlay(alignment: .bottomTrailing) { if isHovered { hoverActions } }
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .onHover { isHovered = $0 }
            // Double click runs the configurable action; single click selects +
            // focuses the row (declare the 2-tap first so SwiftUI can disambiguate
            // from the 1-tap).
            .onTapGesture(count: 2) { performDoubleClick() }
            .onTapGesture(count: 1) { vm.selectFromClick(card) }
            .contextMenu { contextMenu }
    }

    /// Image/color cards are their own fill; the rest get a subtle panel.
    private var cardFill: Color {
        if card.kind == .image || card.kind == .color { return Color.black.opacity(0.25) }
        return Color.white.opacity(isSelected ? 0.10 : (isHovered ? 0.07 : 0.04))
    }

    /// No border on the flush image/color cards (the visual is the boundary);
    /// a subtle dark-grey hairline on text/link/file so they don't vanish into
    /// the black. Selected (keyboard nav) always gets the accent outline.
    private var strokeColor: Color {
        if isSelected { return Color.accentColor.opacity(0.85) }
        if card.kind == .image || card.kind == .color { return .clear }
        return Color(white: 0.2)
    }

    private var pinMarker: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(4)
            .background(Circle().fill(.black.opacity(0.35)))
            .padding(5)
    }

    // MARK: - Hover actions (exactly three, top-right)

    private var hoverActions: some View {
        HStack(spacing: 4) {
            CardActionButton(systemName: pasteGlyph, tint: feedbackTint(pasteState), help: "Paste into current field") {
                Task { flash($pasteState, await vm.paste(card) ? .ok : .fail) }
            }
            CardActionButton(systemName: copied ? "checkmark" : "doc.on.doc", tint: copied ? TerminalColors.green : .secondary, help: "Copy") {
                vm.copy(card); flashCopied()
            }
            CardActionButton(systemName: sendGlyph, tint: feedbackTint(sendState), help: "Send to agent") {
                Task {
                    switch await vm.send(card) {
                    case .delivered: flash($sendState, .ok)
                    case .failed: flash($sendState, .fail)
                    case .awaitingPick: break
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(5)
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

    // MARK: - Right-click menu (Pin / Delete + obvious extras)

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

    // MARK: - Double-click (configurable)

    private func performDoubleClick() {
        switch Defaults[.cardDoubleClickAction] {
        case .copy:
            vm.copy(card); flashCopied()
        case .pasteToField:
            Task { flash($pasteState, await vm.paste(card) ? .ok : .fail) }
        case .sendToAgent:
            Task {
                switch await vm.send(card) {
                case .delivered: flash($sendState, .ok)
                case .failed: flash($sendState, .fail)
                case .awaitingPick: break
                }
            }
        }
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
}

// MARK: - Hover action button (own hover highlight + tooltip)

private struct CardActionButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
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

// MARK: - Shared footer (source-app glyph · time · size)

private struct CardFooter: View {
    let card: UnifiedCard
    var sizeText: String?
    /// White-on-scrim styling for the full-bleed image/color cards.
    var onImage: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            sourceGlyph.frame(width: 12, height: 12)

            if let date = card.date {
                Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                    .lineLimit(1)
            } else if card.isPinned {
                Text("Saved").lineLimit(1)
            }

            Spacer(minLength: 0)

            if let sizeText {
                Text(sizeText)
            } else if card.isTruncatedText {
                Text("trimmed")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(onImage ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
    }

    private var sourceGlyph: some View {
        Group {
            if let icon = Self.appIcon(for: card.sourceBundleId) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: kindSymbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(onImage ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
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

/// Bottom scrim + label used by the flush image/color cards.
private struct FlushCaption: View {
    let card: UnifiedCard
    let title: String
    var sizeText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(card.fileURL?.path ?? title)
            CardFooter(card: card, sizeText: sizeText, onImage: true)
        }
        .padding(.horizontal, 7)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }
}

// MARK: - Inset content types (padded, footer below)

private struct TextCardContent: View {
    let card: UnifiedCard

    private var body3: String { card.rawText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Mono for things that look like code/paths (cheap heuristic, preview only).
    private var usesMono: Bool {
        let s = body3
        return s.contains("/") || s.contains("{") || s.contains(";") || s.contains("()") || s.contains("=>")
    }

    private var truncation: Text.TruncationMode {
        (usesMono && !body3.contains(" ")) ? .middle : .tail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(body3.isEmpty ? "(empty)" : body3)
                .font(usesMono ? .system(size: 11.5, design: .monospaced) : .system(size: 13))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(3)
                .truncationMode(truncation)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .help(String(body3.prefix(600)))
            CardFooter(card: card)
        }
        .padding(8)
    }
}

private struct LinkCardContent: View {
    let card: UnifiedCard

    private var host: String { card.linkURL?.host ?? card.previewText }
    private var path: String? {
        guard let u = card.linkURL, !u.path.isEmpty, u.path != "/" else { return nil }
        return u.path + (u.query.map { "?\($0)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(host)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(card.linkURL?.absoluteString ?? host)
            }
            if let path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            CardFooter(card: card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit) }
                    else { Image(systemName: "doc").font(.system(size: 22)).foregroundStyle(.tertiary) }
                }
                .frame(width: 44, height: 44)

                Text(card.previewText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(card.fileURL?.path ?? card.previewText)

                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            CardFooter(card: card, sizeText: sizeText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if let url = card.fileURL { sizeText = FileSizeFormatter.string(for: url) } }
    }
}

// MARK: - Flush content types (edge-to-edge, caption on scrim)

private struct ColorCardContent: View {
    let card: UnifiedCard

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: card.color ?? .clear)
            FlushCaption(card: card, title: card.colorHex ?? "")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImageCardContent: View {
    let card: UnifiedCard
    @State private var thumbnail: NSImage?
    @State private var sizeText: String?

    var body: some View {
        // `Color.clear` FIXES the layout size to the card box; the image fills +
        // crops as an overlay so its overflow can't enlarge the layout (a flexible
        // `.frame(maxWidth: .infinity)` on a `.fill` image reports a width wider
        // than the card and shifts everything left). The caption then anchors to
        // this fixed box, pinned inside the card's bottom edge.
        Color.clear
            .overlay { thumbnailLayer }
            .clipped()
            .overlay(alignment: .bottom) {
                FlushCaption(card: card, title: card.previewText, sizeText: sizeText)
            }
            .task { await load() }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Color.white.opacity(0.05)
                .overlay(Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.tertiary))
        }
    }

    private func load() async {
        guard let url = card.fileURL else { return }
        sizeText = FileSizeFormatter.string(for: url)
        // iconMode:false → edge-to-edge content thumbnail, no white file-icon frame.
        if let image = await ThumbnailService.shared.thumbnail(for: url, size: CGSize(width: 240, height: 240), iconMode: false) {
            thumbnail = image
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
