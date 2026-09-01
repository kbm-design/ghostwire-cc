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
//  GW-166 — CREDENTIAL PROTECTION. Capture flags credential-shaped text
//  (`CredentialShapeDetector`); this store is where that flag becomes real:
//  `record()` seals such an entry with AES-256-GCM before it ever reaches
//  `entries`, so the plaintext exists nowhere but the pasteboard it came from.
//  On disk the entry carries `sealed` (nonce‖ciphertext‖tag) with `content` nil.
//  Reading it back is `plaintext(of:)`, which every caller reaches through
//  `SensitiveClipAccess` (Touch ID). If the key is unavailable the record is
//  DROPPED, not stored in the clear — the one place the ticket's "keep the clip,
//  gate access" gives way, because the alternative is the bug we're fixing.
//

import Combine
import CryptoKit
import Defaults
import Foundation
import os

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
    /// GW-166: capture judged this text credential-shaped. Once the store has
    /// sealed it, `content` is nil and `sealed` holds the ciphertext.
    let isSensitive: Bool
    /// `CredentialShape` rawValue that matched, for the masked card's label.
    /// A rawValue this build doesn't know still reads as sensitive, unlabeled.
    let sensitiveShape: String?
    /// AES-256-GCM combined box (nonce‖ciphertext‖tag) of the plaintext.
    let sealed: Data?
    /// Keyed HMAC of the plaintext — the only way to compare two sealed clips
    /// for dedupe, since GCM re-nonces every seal. Useless without the key.
    let fingerprint: String?

    nonisolated init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        content: String? = nil,
        path: String? = nil,
        sourceBundleId: String? = nil,
        truncated: Bool = false,
        isTemporary: Bool = false,
        isSensitive: Bool = false,
        sensitiveShape: String? = nil,
        sealed: Data? = nil,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind.rawValue
        self.content = content
        self.path = path
        self.sourceBundleId = sourceBundleId
        self.truncated = truncated
        self.isTemporary = isTemporary
        self.isSensitive = isSensitive
        self.sensitiveShape = sensitiveShape
        self.sealed = sealed
        self.fingerprint = fingerprint
    }

    // Back-compat decode: every field except id/date/kind is optional-with-
    // default so older clipboard-history.json (no `isTemporary`/`truncated`/
    // GW-166's sealed fields) still loads instead of being salvaged away.
    enum CodingKeys: String, CodingKey {
        case id, date, kind, content, path, sourceBundleId, truncated, isTemporary
        case isSensitive, sensitiveShape, sealed, fingerprint
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
        isSensitive = try c.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
        sensitiveShape = try c.decodeIfPresent(String.self, forKey: .sensitiveShape)
        sealed = try c.decodeIfPresent(Data.self, forKey: .sealed)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
    }

    var resolvedKind: Kind { Kind(rawValue: kind) ?? .text }

    /// The shape rule that flagged this entry, when this build recognises it.
    var credentialShape: CredentialShape? {
        sensitiveShape.flatMap(CredentialShape.init(rawValue:))
    }

    /// Human label for the masked card. Falls back to a neutral word when the
    /// stored shape came from a newer build.
    var sensitiveLabel: String { credentialShape?.label ?? "Sensitive" }

    /// Content used for consecutive-dedupe comparison: the keyed fingerprint for
    /// a sealed entry (its plaintext isn't available here), else text or path.
    /// Nil means "not comparable" — `record` treats that as never-equal.
    var dedupeValue: String? {
        if isSensitive { return fingerprint }
        switch resolvedKind {
        case .text: return content
        case .file: return path
        }
    }

    /// GW-166: the sealed form of this entry — plaintext dropped, ciphertext and
    /// fingerprint in its place.
    nonisolated func sealing(box: Data, fingerprint: String) -> ClipboardEntry {
        ClipboardEntry(
            id: id, date: date, kind: resolvedKind,
            content: nil, path: path, sourceBundleId: sourceBundleId,
            truncated: truncated, isTemporary: isTemporary,
            isSensitive: true, sensitiveShape: sensitiveShape,
            sealed: box, fingerprint: fingerprint
        )
    }

    /// GW-166: the un-flagged form ("Not sensitive") — plaintext restored, every
    /// trace of the sealed representation cleared.
    nonisolated func unsealing(content: String) -> ClipboardEntry {
        ClipboardEntry(
            id: id, date: date, kind: resolvedKind,
            content: content, path: path, sourceBundleId: sourceBundleId,
            truncated: truncated, isTemporary: isTemporary,
            isSensitive: false, sensitiveShape: nil,
            sealed: nil, fingerprint: nil
        )
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { Self.reapDroppedTempFiles(old: oldValue, new: entries) }
    }

    private let fileURL: URL
    /// GW-166 seam: where the AES key comes from. Tests inject an in-memory one
    /// so the suite never reaches the user's Keychain.
    private let keyStore: ClipboardKeyStore
    /// Fixed caps in place of the live settings. Tests inject these so the suite
    /// neither reads nor writes the user's defaults domain (GW-444: the XCTest
    /// host IS the live app, and its settings are the user's real ones).
    private let limitsOverride: Limits?
    private var limitsCancellable: AnyCancellable?
    /// Serial queue keeps writes ordered while off the main actor (F9).
    /// Internal so tests can drain it (`ioQueue.sync {}`). Nonisolated so the
    /// nonisolated temp-file reaper can schedule on it (a queue is Sendable).
    nonisolated static let ioQueue = DispatchQueue(label: "com.ghostwire.clipboard-history-io", qos: .utility)

    nonisolated static let logger = Logger(subsystem: "com.ghostwire.notch", category: "clipboard-history")

    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("clipboard-history.json")

    init(
        fileURL: URL = ClipboardHistoryStore.defaultFileURL,
        keyStore: ClipboardKeyStore = KeychainClipboardKeyStore.shared,
        limits: Limits? = nil
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.limitsOverride = limits
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
    ///
    /// GW-166: a credential-flagged entry is sealed FIRST — dedupe compares the
    /// keyed fingerprint that sealing produces, and nothing unsealed is ever
    /// appended to `entries`. A seal that can't happen drops the clip.
    func record(_ entry: ClipboardEntry) {
        guard let entry = sealedIfNeeded(entry) else { return }

        if let last = entries.last,
           last.resolvedKind == entry.resolvedKind,
           last.isSensitive == entry.isSensitive,
           let value = entry.dedupeValue,
           last.dedupeValue == value {
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

    // MARK: - GW-166 sealing

    /// Seal a credential-flagged entry, or pass a normal one straight through.
    /// Nil when the key is unavailable — the caller drops the clip rather than
    /// writing a credential to disk in the clear.
    private func sealedIfNeeded(_ entry: ClipboardEntry) -> ClipboardEntry? {
        guard entry.isSensitive else { return entry }
        // Already sealed (e.g. re-recorded from a loaded entry) — leave it be.
        if entry.sealed != nil, entry.content == nil { return entry }
        guard let plaintext = entry.content else { return nil }
        guard let key = keyStore.loadOrCreateKey(),
              let box = ClipboardSealer.seal(plaintext, key: key) else {
            Self.logger.error("clipboard: sealing key unavailable — credential-shaped clip dropped")
            return nil
        }
        return entry.sealing(box: box, fingerprint: ClipboardSealer.fingerprint(plaintext, key: key))
    }

    /// The plaintext behind an entry: the stored text for a normal one, the
    /// decrypted body for a sealed one. Nil when the key is gone or the box
    /// doesn't open.
    ///
    /// NOT a gate — every UI path must go through `SensitiveClipAccess`, which
    /// runs LocalAuthentication first. This is deliberately the only decrypting
    /// function, so that rule is checkable by grepping its call sites.
    func plaintext(of entry: ClipboardEntry) -> String? {
        guard entry.isSensitive else { return entry.content }
        guard let sealed = entry.sealed, let key = keyStore.loadOrCreateKey() else { return nil }
        return ClipboardSealer.open(sealed, key: key)
    }

    /// "Not sensitive": un-flag an entry, restoring its plaintext in place. The
    /// caller is responsible for having authenticated first (unsealing exposes
    /// the content to search and to un-gated actions). Returns false when the
    /// entry can't be decrypted.
    @discardableResult
    func markNotSensitive(_ entry: ClipboardEntry) -> Bool {
        guard entry.isSensitive,
              let index = entries.firstIndex(where: { $0.id == entry.id }),
              let plain = plaintext(of: entry) else { return false }
        entries[index] = entries[index].unsealing(content: plain)
        save()
        return true
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

    /// Retention caps. `Limits` exists so `prune()` has one injectable input
    /// instead of reaching into Defaults directly.
    struct Limits: Sendable {
        var maxEntries: Int
        var maxAgeDays: Int
    }

    private var limits: Limits {
        limitsOverride ?? Limits(
            maxEntries: Defaults[.clipboardHistoryMaxEntries],
            maxAgeDays: Defaults[.clipboardHistoryMaxAgeDays]
        )
    }

    private func prune() {
        let limits = limits
        entries = Self.pruned(
            entries,
            maxEntries: limits.maxEntries,
            maxAge: TimeInterval(limits.maxAgeDays) * 86_400,
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
