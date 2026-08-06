//
//  FeedCardView.swift
//  Ghostwire
//
//  GW-259. The feed card renderer. A per-kind content dispatcher
//  (`FeedCardContent`) modeled on `ToolResultContent` and the Shelf's
//  `UnifiedCardContent`, wrapped in the same card chrome idiom as
//  `UnifiedCardView` (fixed frame, fill, hairline stroke, source footer, hover
//  actions). It is deliberately content-only: it knows nothing about the Source
//  that produced the card. Actions are injected closures (copy / send / open) so
//  the rendering layer carries no Source or agent plumbing.
//

import AppKit
import SwiftUI

// MARK: - Card (chrome + actions)

struct FeedCardView: View {
    let card: FeedCard
    /// The Source's freshness verdict (see `FeedCard.isStale`). Stale cards dim
    /// but never blank — the last value stays visible through a refresh.
    var isStale: Bool = false
    /// Copy the card's text. Defaults to writing `plainText` to the pasteboard.
    var onCopy: ((FeedCard) -> Void)? = nil
    /// Send the card to an agent. No default — the button only appears when a
    /// host wires this (full send-to-agent plumbing is a Source-side concern).
    var onSend: ((FeedCard) -> Void)? = nil
    /// Open the card's `link`. Defaults to `NSWorkspace.open`; only shown when the
    /// card has a link.
    var onOpenLink: ((URL) -> Void)? = nil

    @State private var isHovered = false
    @State private var copied = false

    private static let corner: CGFloat = 12

    var body: some View {
        FeedCardContent(card: card)
            .frame(width: UnifiedCardView.cardWidth, height: UnifiedCardView.cardHeight)
            .opacity(isStale ? 0.55 : 1)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(Color(white: 0.2), lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) { if isHovered { hoverActions } }
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .onHover { isHovered = $0 }
    }

    private var cardFill: Color {
        Color.white.opacity(isHovered ? 0.07 : 0.04)
    }

    // MARK: - Hover actions (Copy · Send · Open) — non-destructive only

    private var hoverActions: some View {
        HStack(spacing: 4) {
            CardActionButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                tint: copied ? TerminalColors.green : .secondary,
                help: "Copy"
            ) {
                (onCopy ?? Self.defaultCopy)(card)
                flashCopied()
            }
            if let onSend {
                CardActionButton(systemName: "terminal", tint: .secondary, help: "Send to agent") {
                    onSend(card)
                }
            }
            if let link = card.link {
                CardActionButton(systemName: "arrow.up.forward.app", tint: .secondary, help: "Open link") {
                    (onOpenLink ?? { NSWorkspace.shared.open($0) })(link)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(5)
    }

    private static func defaultCopy(_ card: FeedCard) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.plainText, forType: .string)
    }

    private func flashCopied() {
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation { copied = false } }
        }
    }
}

// MARK: - Per-kind content dispatcher (modeled on ToolResultContent / UnifiedCardContent)

struct FeedCardContent: View {
    let card: FeedCard

    var body: some View {
        switch card.kind {
        case .text:    TextFeedCardContent(card: card)
        case .data:    DataFeedCardContent(card: card)
        case .list:    ListFeedCardContent(card: card)
        case .generic: GenericFeedCardContent(card: card)
        }
    }
}

// MARK: - Shared footer (source-app glyph · time)

private struct FeedCardFooter: View {
    let card: FeedCard

    var body: some View {
        HStack(spacing: 5) {
            sourceGlyph.frame(width: 12, height: 12)
            Text(card.relativeUpdatedText())
                .lineLimit(1)
            Spacer(minLength: 0)
            if card.link != nil {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private var sourceGlyph: some View {
        Group {
            if let icon = sourceAppIcon(for: card.sourceApp) {
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
        case .text:    return "text.alignleft"
        case .data:    return "number"
        case .list:    return "list.bullet"
        case .generic: return "square.dashed"
        }
    }

}

// MARK: - Content renderers (padded, footer below — the Shelf text-card idiom)

private struct TextFeedCardContent: View {
    let card: FeedCard

    var body: some View {
        let (title, body) = Self.fields(card.kind)
        return VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(body.isEmpty ? "(empty)" : body)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(title.isEmpty ? 4 : 3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .help(String(body.prefix(600)))
            FeedCardFooter(card: card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func fields(_ kind: FeedCardKind) -> (String, String) {
        if case let .text(title, body) = kind { return (title, body) }
        return ("", "")
    }
}

private struct DataFeedCardContent: View {
    let card: FeedCard

    var body: some View {
        let (label, value, delta) = Self.fields(card.kind)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let delta {
                Text(delta)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Self.deltaTint(delta))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            FeedCardFooter(card: card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Color a signed delta green/red off its leading sign; neutral otherwise.
    private static func deltaTint(_ delta: String) -> Color {
        let t = delta.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-") { return TerminalColors.red }
        if t.hasPrefix("+") { return TerminalColors.green }
        return .secondary
    }

    private static func fields(_ kind: FeedCardKind) -> (String, String, String?) {
        if case let .data(label, value, delta) = kind { return (label, value, delta) }
        return ("", "", nil)
    }
}

private struct ListFeedCardContent: View {
    let card: FeedCard

    var body: some View {
        let (title, items) = Self.fields(card.kind)
        return VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if items.count > 3 {
                    Text("+\(items.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            FeedCardFooter(card: card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func fields(_ kind: FeedCardKind) -> (String, [String]) {
        if case let .list(title, items) = kind { return (title, items) }
        return ("", [])
    }
}

private struct GenericFeedCardContent: View {
    let card: FeedCard

    var body: some View {
        let (title, subtitle, value) = Self.fields(card.kind)
        return VStack(alignment: .leading, spacing: 3) {
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            FeedCardFooter(card: card)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func fields(_ kind: FeedCardKind) -> (String, String?, String?) {
        if case let .generic(title, subtitle, value) = kind { return (title, subtitle, value) }
        return ("", nil, nil)
    }
}
