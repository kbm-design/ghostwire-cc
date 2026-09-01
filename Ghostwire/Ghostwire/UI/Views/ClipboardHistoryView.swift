//
//  ClipboardHistoryView.swift
//  Ghostwire
//
//  GW-210: clipboard history surfaced inside the Shelf tab. The Shelf's own
//  layout is a horizontal drag-tile strip — a vertical history list with hover
//  row-actions doesn't fit that idiom, so this uses the approved alternative:
//  a compact access row (ClipboardHistoryAccessRow) appended under the shelf
//  panel that swaps in this full ClipboardHistoryView (back-chevron header,
//  no new window). Same swap idiom as AlertHistoryView (GW-208).
//
//  House style (matches AlertHistoryView): quiet captions, glyph/tint over
//  labels, newest-first rich one-line rows. Mono preview for code/paths.
//  Row hover actions: re-copy (stamps our marker type), pin-to-shelf (converts
//  to a regular Shelf .text/.file item), delete. The action enum is the clean
//  seam for GW-164's "send to agent" — add a case, no row restructure.
//
//  GW-166: a sealed (credential-shaped) entry renders masked with a lock glyph
//  and gains reveal / "not sensitive" actions. Re-copy and send-to-agent route
//  through `SensitiveClipAccess` (Touch ID) first; pin-to-shelf is refused,
//  because the Shelf store is plaintext-at-rest.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Row actions (extension seam for GW-164 send-to-agent)

/// What a clipboard row's hover actions can do. GW-164 extends this with a
/// `.sendToAgent` case + a handler; nothing else in the row changes.
enum ClipboardRowAction {
    case recopy
    case pinToShelf
    case sendToAgent
    case delete
    /// GW-166: show a sealed entry's plaintext in place (Touch ID first).
    case reveal
    /// GW-166: un-flag a sealed entry so it behaves like any other clip.
    case notSensitive
}

// MARK: - Full swap-view

/// Full "Clipboard" view, swapped into the Shelf tab when the access row is
/// tapped (AlertHistoryView idiom): back-chevron header + Clear, then the
/// newest-first rows. When disabled, shows a single enable affordance.
struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @Default(.clipboardHistoryEnabled) private var enabled
    let onBack: () -> Void

    /// Newest first — the store keeps oldest-first for pruning.
    private var entries: [ClipboardEntry] {
        store.entries.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if !enabled {
                disabledState
            } else if entries.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            ClipboardHistoryRow(entry: entry)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    /// Back chevron + "Clipboard" + a small Clear (AlertHistoryView header idiom).
    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Clipboard")
                        .font(.subheadline.weight(.medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Shelf")

            Spacer()

            if enabled && !store.entries.isEmpty {
                Button(action: { store.clear() }) {
                    Text("Clear")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove all clipboard history")
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing copied yet")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 16)
    }

    /// Opt-in by default (privacy): one quiet enable affordance.
    private var disabledState: some View {
        VStack(spacing: 8) {
            Text("Clipboard history is off")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: { enabled = true }) {
                Text("Turn on")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            Text("Captured locally. Password-manager and transient copies are skipped, and anything that looks like a credential is encrypted behind Touch ID.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 16)
    }
}

// MARK: - Access row

/// Compact access row appended under the shelf panel: clip glyph + "Clipboard"
/// + count + chevron, quiet styling. Tapping it swaps in ClipboardHistoryView.
/// Renders even when empty/disabled so the entry point (and the enable
/// affordance behind it) is always reachable from the Shelf tab.
struct ClipboardHistoryAccessRow: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @Default(.clipboardHistoryEnabled) private var enabled
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)

                Text("Clipboard")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if enabled {
                    Text("\(store.entries.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Off")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Row

/// One clipboard entry, one line: kind glyph + 1-line preview (mono for things
/// that look like code/paths) + relative time, with re-copy / pin / delete
/// hover actions. No name pills (house style).
private struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry

    @State private var isHovered = false
    @State private var didCopy = false
    /// GW-166: plaintext of a sealed entry after a successful unlock. View state
    /// only — it dies with the row.
    @State private var revealed: String?
    /// GW-163: send-to-agent feedback — glyph swaps to a checkmark on delivery,
    /// to a slash on a quiet failure (no agent reachable). Resets after a beat.
    @State private var sendFeedback: SendFeedback = .idle

    private enum SendFeedback { case idle, sent, failed }

    private var preview: String {
        if entry.isSensitive {
            // Fixed-length mask — the row never hints at the secret's length.
            return revealed ?? String(repeating: "•", count: 16)
        }
        switch entry.resolvedKind {
        case .file:
            return (entry.path as NSString?)?.lastPathComponent ?? entry.path ?? ""
        case .text:
            let body = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = body.components(separatedBy: .newlines).first ?? body
            return firstLine
        }
    }

    /// Mono for file paths and text that looks like code (no spaces but has
    /// path/symbol punctuation). Cheap heuristic — preview only.
    private var usesMono: Bool {
        if entry.isSensitive { return true }
        if entry.resolvedKind == .file { return true }
        let s = preview
        guard !s.isEmpty else { return false }
        let looksPathy = s.contains("/") || s.contains("\\")
        let codey = s.contains("{") || s.contains(";") || s.contains("()") || s.contains("=>")
        return looksPathy || codey
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(entry.isSensitive ? AnyShapeStyle(TerminalColors.amber) : AnyShapeStyle(.tertiary))
                .frame(width: 12)
                .help(entry.isSensitive ? entry.sensitiveLabel : "")

            Text(preview.isEmpty ? "(empty)" : preview)
                .font(usesMono ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(entry.resolvedKind == .file ? .middle : .tail)

            if entry.isSensitive, revealed == nil {
                Text(entry.sensitiveLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if entry.truncated {
                Text("…trimmed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if isHovered {
                actions
            } else {
                Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if entry.isSensitive {
                actionButton(
                    systemName: revealed == nil ? "eye" : "eye.slash",
                    help: revealed == nil ? "Reveal (requires Touch ID)" : "Hide"
                ) { perform(.reveal) }
            }

            actionButton(
                systemName: didCopy ? "checkmark" : "doc.on.doc",
                help: "Copy"
            ) { perform(.recopy) }

            // Pin is absent for a sealed entry: the Shelf store is plaintext.
            if !entry.isSensitive {
                actionButton(systemName: "pin", help: "Pin to shelf") { perform(.pinToShelf) }
            } else {
                actionButton(systemName: "lock.open", help: "Not sensitive") { perform(.notSensitive) }
            }

            actionButton(systemName: sendGlyph, help: "Send to agent", tint: sendTint) { perform(.sendToAgent) }

            actionButton(systemName: "trash", help: "Delete") { perform(.delete) }
        }
        .layoutPriority(1)
    }

    private var glyph: String {
        if entry.isSensitive { return revealed == nil ? "lock.fill" : "lock.open.fill" }
        return entry.resolvedKind == .file ? "doc" : "text.alignleft"
    }

    private func actionButton(systemName: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// GW-163: terminal/arrow glyph; swaps to a checkmark on delivery and a
    /// slashed glyph on a quiet failure.
    private var sendGlyph: String {
        switch sendFeedback {
        case .idle: return "terminal"
        case .sent: return "checkmark"
        case .failed: return "terminal.fill"
        }
    }

    private var sendTint: Color {
        switch sendFeedback {
        case .idle: return .secondary
        case .sent: return TerminalColors.green
        case .failed: return TerminalColors.amber
        }
    }

    /// Single dispatch point — the seam GW-164 extends. Adding `.sendToAgent`
    /// here is the entire row-side change.
    private func perform(_ action: ClipboardRowAction) {
        switch action {
        case .recopy:
            recopy()
        case .pinToShelf:
            // Refused for a sealed entry — the Shelf store is plaintext-at-rest.
            guard !entry.isSensitive else { return }
            pinToShelf()
        case .sendToAgent:
            sendToAgent()
        case .delete:
            ClipboardHistoryStore.shared.remove(entry)
        case .reveal:
            guard entry.isSensitive else { return }
            if revealed == nil {
                Task { revealed = await unlock(Self.reasonReveal) }
            } else {
                hideRevealed()
            }
        case .notSensitive:
            guard entry.isSensitive else { return }
            Task {
                guard await unlock(Self.reasonUnflag) != nil else { return }
                ClipboardHistoryStore.shared.markNotSensitive(entry)
                hideRevealed()
            }
        }
    }

    /// GW-166: a sealed entry has no plaintext to re-copy directly — unlock it,
    /// then stage the decrypted text as one of our own writes (so the poller
    /// doesn't re-capture it, this time unflagged).
    private func recopy() {
        if entry.isSensitive {
            Task {
                guard let plain = await unlock(Self.reasonCopy) else { return }
                ClipboardHistoryService.shared.stagePlainTextForPaste(plain)
                flashCopied()
            }
            return
        }
        ClipboardHistoryService.shared.recopy(entry)
        flashCopied()
    }

    private func flashCopied() {
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation { didCopy = false } }
        }
    }

    private func unlock(_ reason: String) async -> String? {
        await SensitiveClipAccess.shared.plaintext(for: entry, reason: reason)
    }

    private func hideRevealed() {
        revealed = nil
        SensitiveClipAccess.shared.relock(entry.id)
    }

    private static let reasonReveal = "reveal a sensitive clipboard item"
    private static let reasonCopy = "copy a sensitive clipboard item"
    private static let reasonSend = "send a sensitive clipboard item to an agent"
    private static let reasonUnflag = "unlock a sensitive clipboard item"

    /// GW-163: route this entry to the active agent's input. Text → inject(text:),
    /// file → inject(file:). The coordinator handles target resolution + picker;
    /// here we only reflect the immediate outcome in the glyph (the picker path
    /// resolves on its own, so it reads as a quiet no-op confirmation).
    private func sendToAgent() {
        // GW-166: a sealed entry unlocks first, then sends the decrypted text.
        if entry.isSensitive {
            Task {
                guard let plain = await unlock(Self.reasonSend) else {
                    flashSendFeedback(.failed)
                    return
                }
                switch await SendToAgentCoordinator.shared.send(.text(plain)) {
                case .delivered: flashSendFeedback(.sent)
                case .failed: flashSendFeedback(.failed)
                case .awaitingPick: break
                }
            }
            return
        }

        let payload: SendToAgentCoordinator.Payload
        switch entry.resolvedKind {
        case .text:
            guard let content = entry.content, !content.isEmpty else { return }
            payload = .text(content)
        case .file:
            guard let path = entry.path,
                  FileManager.default.fileExists(atPath: path) else {
                flashSendFeedback(.failed)
                return
            }
            payload = .file(URL(fileURLWithPath: path))
        }

        Task { @MainActor in
            let result = await SendToAgentCoordinator.shared.send(payload)
            switch result {
            case .delivered:
                flashSendFeedback(.sent)
            case .failed:
                flashSendFeedback(.failed)
            case .awaitingPick:
                // Picker is showing; the user's choice carries the feedback.
                break
            }
        }
    }

    private func flashSendFeedback(_ state: SendFeedback) {
        withAnimation { sendFeedback = state }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation { sendFeedback = .idle } }
        }
    }

    /// Convert this entry into a regular Shelf item so it persists in the hold-
    /// store. Text → `.text`; file path → a security-scoped `.file` bookmark
    /// (only when the file still exists), else fall back to the path as text.
    private func pinToShelf() {
        switch entry.resolvedKind {
        case .text:
            guard let content = entry.content else { return }
            ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: content))])
        case .file:
            guard let path = entry.path else { return }
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let bookmark = try? url.bookmarkData(
                   options: [.withSecurityScope],
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark))])
            } else {
                ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: path))])
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
