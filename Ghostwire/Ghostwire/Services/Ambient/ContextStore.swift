//
//  ContextStore.swift
//  Ghostwire
//
//  GW-172 — persistence for the ambient spine. Per-day JSON shards under
//  Application Support/Ghostwire/Ambient/ (bounds file size, makes retention a
//  file delete, keeps any single corruption to one day). In-memory ring capped
//  ~2k events. Writes are atomic and run off the main actor; corrupt entries are
//  salvaged per-item rather than discarding a whole shard (the AlertHistoryStore
//  / Shelf pattern).
//
//  Honesty rules (architecture §3) enforced here:
//   • loginwindow + kin filtered defensively on load (also filtered at capture).
//   • Retention prune on launch and on day-rollover.
//   • session-only retention = RAM only; nothing is persisted, and switching to
//     it wipes any shards already on disk.
//
//  SILENT phase: stored only for Ghostwire's own future surfacing (GW-182/214).
//  Local-only — never narrated to a cloud agent.
//

import Defaults
import Foundation

@MainActor
final class ContextStore: ObservableObject {
    static let shared = ContextStore()

    /// Recent streaks, newest last. Capped at `maxInMemoryEvents`.
    @Published private(set) var events: [ContextEvent] = []

    /// In-memory ring cap (architecture §3).
    static let maxInMemoryEvents = 2_000

    /// Gap beyond which a matching fingerprint starts a fresh streak instead of
    /// extending — ≈2× the observer backstop interval, so a lock/sleep gap always
    /// exceeds it (see `AmbientContextService.backstopInterval`).
    static let maxGap: TimeInterval = 180

    private let directory: URL
    /// Serial queue keeps shard writes/deletes ordered while off the main actor.
    /// Internal so tests can drain it (`ioQueue.sync {}`).
    static let ioQueue = DispatchQueue(label: "com.ghostwire.ambient-io", qos: .utility)

    private static let defaultDirectory: URL = {
        let fm = FileManager.default
        let support = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return (support ?? fm.temporaryDirectory)
            .appendingPathComponent("Ghostwire", isDirectory: true)
            .appendingPathComponent("Ambient", isDirectory: true)
    }()

    init(directory: URL = ContextStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    /// Touch the singleton at launch so the first capture doesn't pay the load()
    /// disk read on the activation path.
    func warm() {}

    // MARK: - Capture

    /// Fold a recordable snapshot into the streak list and persist its day shard.
    /// The caller (AmbientContextService) has already applied the capture filter.
    func record(_ snapshot: ContextSnapshot) {
        let previousLast = events.last
        events = ContextStreak.folding(events, with: snapshot, maxGap: Self.maxGap)

        // Cap the in-memory ring (age pruning happens on load + day-rollover).
        if events.count > Self.maxInMemoryEvents {
            events = Array(events.suffix(Self.maxInMemoryEvents))
        }

        // session-only: keep it in RAM, never touch disk.
        guard Defaults[.ambientRetention] != .sessionOnly else { return }

        if let affected = events.last {
            persistShard(forDay: affected.start)
            // A fresh streak on a new day is the cheap, natural moment to prune
            // shards that fell out of the retention window.
            if previousLast == nil
                || !Calendar.current.isDate(previousLast!.start, inSameDayAs: affected.start) {
                pruneDisk()
            }
        }
    }

    // MARK: - Deletion

    /// Remove every persisted shard (memory is left intact — used when the user
    /// switches retention to session-only).
    func deleteAllPersisted() {
        let dir = directory
        Self.ioQueue.async {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// "Delete all activity data" — clears memory and disk.
    func deleteAllData() {
        events = []
        deleteAllPersisted()
    }

    // MARK: - Pruning (pure — unit-tested)

    /// Streaks active within `maxAge` (nil = forever), oldest-first, capped to the
    /// newest `maxCount`. A streak is kept while its trailing edge is in window,
    /// so an ongoing streak isn't dropped by an old `start`.
    nonisolated static func pruned(
        _ events: [ContextEvent],
        maxAge: TimeInterval?,
        maxCount: Int,
        now: Date
    ) -> [ContextEvent] {
        var result = events.sorted { $0.start < $1.start }
        if let maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            result = result.filter { $0.end >= cutoff }
        }
        return Array(result.suffix(max(0, maxCount)))
    }

    // MARK: - Persistence

    /// Per-item salvage wrapper: one corrupt event doesn't discard a whole shard.
    private struct SalvagedEvent: Decodable {
        let value: ContextEvent?
        init(from decoder: Decoder) { value = try? ContextEvent(from: decoder) }
    }

    private func load() {
        // session-only never reads from disk, and clears any leftover shards so
        // a setting change can't resurrect old activity.
        guard Defaults[.ambientRetention] != .sessionOnly else {
            deleteAllPersisted()
            return
        }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let shardURLs = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var loaded: [ContextEvent] = []
        for url in shardURLs {
            guard let data = try? Data(contentsOf: url),
                  let salvaged = try? Self.decoder.decode([SalvagedEvent].self, from: data)
            else { continue }
            loaded.append(contentsOf: salvaged.compactMap(\.value))
        }

        // Defensive lock-screen filter on load (architecture §3 honesty rule).
        loaded = loaded.filter { !ContextStreak.excludedBundleIDs.contains($0.bundleID) }

        events = Self.pruned(
            loaded,
            maxAge: Defaults[.ambientRetention].maxAge,
            maxCount: Self.maxInMemoryEvents,
            now: Date()
        )
        pruneDisk()
    }

    /// Rewrite the shard for `day` from the in-memory events that fall on it.
    private func persistShard(forDay day: Date) {
        let dayEvents = events.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        let url = shardURL(for: day)
        guard let data = try? Self.encoder.encode(dayEvents) else { return }
        Self.ioQueue.async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Delete shard files whose day is older than the retention window.
    private func pruneDisk() {
        guard let maxAge = Defaults[.ambientRetention].maxAge else { return }  // forever
        let cutoffDay = Calendar.current.startOfDay(for: Date().addingTimeInterval(-maxAge))
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            guard let day = Self.dayFormatter.date(from: name), day < cutoffDay else { continue }
            Self.ioQueue.async { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func shardURL(for day: Date) -> URL {
        directory.appendingPathComponent("\(Self.dayFormatter.string(from: day)).json")
    }

    /// Local-time `yyyy-MM-dd` so a shard's day matches the user's wall day.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
