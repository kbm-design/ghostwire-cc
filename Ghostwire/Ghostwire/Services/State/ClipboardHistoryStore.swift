//
//  ClipboardHistoryStore.swift
//  Ghostwire
//
//  GW-210: clipboard history — the governed, capped store of what the user
//  copied. The "hold" half of the GW-163 killer flow. Mirrors
//  AlertHistoryStore's idiom exactly: @MainActor ObservableObject, JSON
//  persistence to the app's dot-dir, atomic off-actor writes, cap + max-age
//  enforcement that re-prunes when the settings change.
//
//  Persists to ~/.ghostwire/clipboard-history.json (the app's dot-dir; the
//  Shelf keeps its own store under Application Support). Writes are atomic
//  and run off the main actor; corrupt entries are salvaged per-item rather
//  than discarding the whole file (review F7/F9 — same as AlertHistoryStore).
//
//  PRIVACY (GW-210 hard requirements, enforced in ClipboardHistoryService —
//  this store only persists what it's handed): concealed/transient pasteboard
//  contents are never recorded; our own re-copies are skipped; captured text
//  is length-capped. Nothing here leaves the machine (local-first).
//

import Combine
import Defaults
import Foundation

/// One recorded clipboard entry. `kind` is a string for forward-compat in the
/// JSON (new kinds decode as `.unknown` rather than failing the whole file).
struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case file
    }

    let id: UUID
    var date: Date
    /// "text" | "file" (raw string for forward-compat).
    let kind: String
    /// Plain text payload (kind == text) — already length-capped at capture.
    let content: String?
    /// File path (kind == file) — captured from an `.fileURL` pasteboard item.
    let path: String?
    /// Bundle id of the frontmost app at capture, best-effort. nil if unknown.
    let sourceBundleId: String?
    /// True when capture truncated `content` to the configured byte cap.
    let truncated: Bool
    /// GW-218: true when `path` points at a temp file we spilled (e.g. a copied
    /// raw image). Such files are reaped when the entry drops out of history.
    /// Additive field — decodes as `false` from pre-GW-218 JSON.
    let isTemporary: Bool

    nonisolated init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        content: String? = nil,
        path: String? = nil,
        sourceBundleId: String? = nil,
        truncated: Bool = false,
        isTemporary: Bool = false
    ) {
        self.id = id
        self.date = date
        self.kind = kind.rawValue
        self.content = content
        self.path = path
        self.sourceBundleId = sourceBundleId
        self.truncated = truncated
        self.isTemporary = isTemporary
    }

    // Back-compat decode: every field except id/date/kind is optional-with-
    // default so older clipboard-history.json (no `isTemporary`/`truncated`)
    // still loads instead of being salvaged away.
    enum CodingKeys: String, CodingKey {
        case id, date, kind, content, path, sourceBundleId, truncated, isTemporary
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decode(String.self, forKey: .kind)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        sourceBundleId = try c.decodeIfPresent(String.self, forKey: .sourceBundleId)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        isTemporary = try c.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
    }

    var resolvedKind: Kind { Kind(rawValue: kind) ?? .text }

    /// Content used for consecutive-dedupe comparison: text body or file path.
    var dedupeValue: String? {
        switch resolvedKind {
        case .text: return content
        case .file: return path
        }
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { Self.reapDroppedTempFiles(old: oldValue, new: entries) }
    }

    private let fileURL: URL
    private var limitsCancellable: AnyCancellable?
    /// Serial queue keeps writes ordered while off the main actor (F9).
    /// Internal so tests can drain it (`ioQueue.sync {}`). Nonisolated so the
    /// nonisolated temp-file reaper can schedule on it (a queue is Sendable).
    nonisolated static let ioQueue = DispatchQueue(label: "com.ghostwire.clipboard-history-io", qos: .utility)

    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("clipboard-history.json")

    init(fileURL: URL = ClipboardHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()

        // Lowering the caps in settings prunes immediately (review M4),
        // not just on the next record().
        limitsCancellable = Defaults.publisher(keys: .clipboardHistoryMaxEntries, .clipboardHistoryMaxAgeDays)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyLimits() }
            }
    }

    /// Touch the singleton at launch so first-capture recording doesn't pay
    /// the load() disk read on the polling path (review F9).
    func warm() {}

    /// GW-218: delete temp files for `isTemporary` entries that just dropped out
    /// (expiry/cap/delete/clear). `removeTemporaryFileIfNeeded` guards that the
    /// path is inside NSTemporaryDirectory, so this can't touch real files.
    nonisolated static func reapDroppedTempFiles(old: [ClipboardEntry], new: [ClipboardEntry]) {
        let liveIds = Set(new.map(\.id))
        let dropped = old.filter { $0.isTemporary && !liveIds.contains($0.id) }
        guard !dropped.isEmpty else { return }
        for entry in dropped {
            guard let path = entry.path else { continue }
            ioQueue.async {
                TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: URL(fileURLWithPath: path))
            }
        }
    }

    /// Record a freshly captured entry. Consecutive identical content (same
    /// kind + same text/path as the newest entry) updates that entry's
    /// timestamp instead of inserting a duplicate (GW-210 dedupe).
    func record(_ entry: ClipboardEntry) {
        if let last = entries.last,
           last.resolvedKind == entry.resolvedKind,
           last.dedupeValue == entry.dedupeValue {
            entries[entries.count - 1].date = entry.date
            prune()
            save()
            return
        }
        entries.append(entry)
        prune()
        save()
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Re-apply the configured caps; persists only when something fell out.
    func applyLimits() {
        let before = entries.count
        prune()
        if entries.count != before {
            save()
        }
    }

    // MARK: - Pruning

    /// Newest `maxEntries` entries no older than `maxAge`, oldest-first.
    /// Pure — unit-tested directly. Mirrors AlertHistoryStore.pruned.
    nonisolated static func pruned(
        _ entries: [ClipboardEntry],
        maxEntries: Int,
        maxAge: TimeInterval,
        now: Date
    ) -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = entries
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
        return Array(fresh.suffix(max(0, maxEntries)))
    }

    private func prune() {
        entries = Self.pruned(
            entries,
            maxEntries: Defaults[.clipboardHistoryMaxEntries],
            maxAge: TimeInterval(Defaults[.clipboardHistoryMaxAgeDays]) * 86_400,
            now: Date()
        )
    }

    // MARK: - Persistence

    /// Wrapper that swallows undecodable entries so one corrupt item
    /// doesn't discard the whole history (review F7; shelf pattern).
    private struct SalvagedEntry: Decodable {
        let value: ClipboardEntry?
        init(from decoder: Decoder) {
            value = try? ClipboardEntry(from: decoder)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let salvaged = try? Self.decoder.decode([SalvagedEntry].self, from: data) else {
            return
        }
        let stored = salvaged.compactMap(\.value)
        entries = stored
        prune()
        // Write back when load dropped anything (corrupt items or entries
        // over the caps) so disk reflects the enforced limits (review F6).
        if entries.count != stored.count || stored.count != salvaged.count {
            save()
        }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        let url = fileURL
        Self.ioQueue.async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
