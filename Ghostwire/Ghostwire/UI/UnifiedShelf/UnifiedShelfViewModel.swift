//
//  UnifiedShelfViewModel.swift
//  Ghostwire
//
//  GW-218. Merges the two stores into one ordered, de-duplicated feed of
//  `UnifiedCard`s (Approach B — view-layer only, no storage migration):
//    - saved/pinned items  (ShelfStateViewModel)  — persist, expiry-exempt
//    - transient copies     (ClipboardHistoryStore) — roll off / auto-expire
//
//  Ordering: one feed, newest-first (leading edge = most recent). Transient
//  entries sort by capture time; saved items have no `capturedAt` under B, so we
//  keep an in-memory first-seen stamp — fresh drags/pins land at the front, and
//  items carried over from a previous launch settle at the trailing (old) end,
//  i.e. pinned things "pile up" there instead of being evicted. (Keelan, 06-11.)
//
//  Cross-store dedup by `identityKey`: a copied-then-pinned/dragged file shows
//  once, with the saved card winning (so the pin/persistence is what's visible).
//

import AppKit
import Combine
import Foundation

@MainActor
final class UnifiedShelfViewModel: ObservableObject {
    static let shared = UnifiedShelfViewModel()

    @Published private(set) var cards: [UnifiedCard] = []

    private let shelf = ShelfStateViewModel.shared
    private let clipboard = ClipboardHistoryStore.shared
    private var cancellables: Set<AnyCancellable> = []

    /// First-seen time for saved items (no `capturedAt` under Approach B). Stamped
    /// when a saved id is first observed this session. Pin preserves the source
    /// entry's time so a promoted card keeps its place; pre-launch items fall back
    /// to `.distantPast` and settle at the old (trailing) end of the feed.
    private var savedFirstSeen: [UUID: Date] = [:]

    private init() {
        recompute()
        // Defer recompute off the store's own publish to avoid mutating @Published
        // state during a SwiftUI update pass.
        shelf.$items
            .sink { [weak self] _ in Task { @MainActor in self?.recompute() } }
            .store(in: &cancellables)
        clipboard.$entries
            .sink { [weak self] _ in Task { @MainActor in self?.recompute() } }
            .store(in: &cancellables)
    }

    var isEmpty: Bool { cards.isEmpty }

    // MARK: - Merge

    private func recompute() {
        let now = Date()
        let savedItems = shelf.items

        // Prune stamps for items that are gone; stamp newly-seen ones.
        let liveIds = Set(savedItems.map(\.id))
        savedFirstSeen = savedFirstSeen.filter { liveIds.contains($0.key) }
        for item in savedItems where savedFirstSeen[item.id] == nil {
            savedFirstSeen[item.id] = now
        }

        var seenKeys = Set<String>()
        var merged: [(card: UnifiedCard, sort: Date)] = []

        // Saved first so they win dedup against any transient twin.
        for item in savedItems {
            let card = UnifiedCard(source: .saved(item))
            seenKeys.insert(card.identityKey)
            merged.append((card, savedFirstSeen[item.id] ?? .distantPast))
        }
        for entry in clipboard.entries {
            let card = UnifiedCard(source: .transient(entry))
            if seenKeys.contains(card.identityKey) { continue }
            merged.append((card, entry.date))
        }

        cards = merged.sorted { $0.sort > $1.sort }.map(\.card)
    }

    // MARK: - Actions

    /// Pin = promote a transient copy into the saved Shelf (persists, expiry-
    /// exempt). The transient twin stays put but is hidden by dedup, so deleting
    /// the saved card later quietly restores it to the rolling history.
    func pin(_ card: UnifiedCard) {
        guard case .transient(let entry) = card.source,
              let item = Self.makeShelfItem(from: entry) else { return }
        savedFirstSeen[item.id] = entry.date // keep its place in the feed
        shelf.add([item])
        // A spilled-image entry shares its temp file with nothing else; once we've
        // copied it into the saved item we drop the transient twin so its (now
        // orphaned) temp file is reaped and we don't show a stale duplicate. Plain
        // text / real files leave the transient in place — dedup hides it, and
        // deleting the saved card later restores it to the rolling history.
        if entry.isTemporary { clipboard.remove(entry) }
    }

    /// Delete removes the card from its own store (no cross-store side effects).
    /// Saved removal also cleans up any backing temp file via `cleanupStoredData`.
    func delete(_ card: UnifiedCard) {
        switch card.source {
        case .saved(let item): shelf.remove(item)
        case .transient(let entry): clipboard.remove(entry)
        }
    }

    /// Copy = make this card the live clipboard again (marker-stamped so auto-
    /// capture ignores our own write). Files re-copy as real file URLs.
    func copy(_ card: UnifiedCard) {
        ClipboardHistoryService.shared.copyCardToPasteboard(card)
    }

    /// Send to the active agent (staged, never auto-submitted). Text inline,
    /// file as `@path`. Returns the immediate outcome for glyph feedback.
    @discardableResult
    func send(_ card: UnifiedCard) async -> SendToAgentCoordinator.SendResult {
        guard let payload = card.sendPayload else { return .failed }
        return await SendToAgentCoordinator.shared.send(payload)
    }

    /// Paste into the user's current text field: stage the card's plain-text on
    /// the pasteboard, then synthesize ⌘V into the previously-frontmost app.
    /// Works because the notch is a non-activating panel (the prior app keeps key
    /// focus). Requires Accessibility/Input-Monitoring permission. Returns false
    /// when that permission is missing or the keystroke couldn't be posted.
    @discardableResult
    func paste(_ card: UnifiedCard) async -> Bool {
        ClipboardHistoryService.shared.stagePlainTextForPaste(card)
        return await KeystrokePaster.pasteIntoPreviousApp()
    }

    // MARK: - Pin helper

    /// Build a Shelf item from a transient entry (mirrors the old
    /// ClipboardHistoryRow.pinToShelf). File paths become security-scoped
    /// bookmarks when the file still exists; otherwise fall back to the path as
    /// text. A spilled temp image is first COPIED to a fresh temp file so the
    /// saved item is independent of the rolling entry's reaping; we then store it
    /// `isTemporary: false` so our own cleanup won't delete a pinned item.
    private static func makeShelfItem(from entry: ClipboardEntry) -> ShelfItem? {
        switch entry.resolvedKind {
        case .text:
            guard let content = entry.content else { return nil }
            return ShelfItem(kind: .text(string: content))
        case .file:
            guard let path = entry.path else { return nil }
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                return ShelfItem(kind: .text(string: path))
            }
            let target = entry.isTemporary ? (copyToFreshTemp(source) ?? source) : source
            if let bookmark = try? target.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                return ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
            return ShelfItem(kind: .text(string: path))
        }
    }

    /// Duplicate a temp file into a fresh temp dir so a pinned copy survives the
    /// reaping of its rolling-history twin.
    private static func copyToFreshTemp(_ source: URL) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
