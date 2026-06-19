//
//  ToolUsageStore.swift
//  Ghostwire
//
//  GW-184: local-only recency+frequency log behind the gateway's working set.
//  Each gateway tool call records the exposed name; buildExposure reads the
//  snapshot to pick the ~25 tools worth exposing directly (the rest stay
//  reachable via search_tools/call_tool). Never leaves the machine.
//

import Foundation

/// One tool's usage: how often, and most recently when.
struct ToolUsage: Codable, Equatable, Sendable {
    var count: Int
    var lastUsedAt: Date
}

/// What the gateway core records into. An actor in production; faked in unit
/// tests. Sendable so the `Sendable` core can hold it behind the SDK's
/// `@Sendable` server handlers.
protocol ToolUsageRecording: Sendable {
    func record(_ exposedName: String) async
    func snapshot() async -> [String: ToolUsage]
}

/// Tunables for the working set + search fallback. Defaults are the GW-184
/// decisions: 15 most-recent ∪ 10 most-frequent (~25 cap), search returns 10.
struct WorkingSetConfig: Sendable, Equatable {
    var recencyLimit: Int = 15
    var frequencyLimit: Int = 10
    var cap: Int = 25
    var searchLimit: Int = 10

    static let `default` = WorkingSetConfig()
}

/// Disk-backed usage log. Writes through on every record (tool calls are not a
/// hot loop) with atomic replace; a corrupt file salvages to empty rather than
/// blocking writes.
actor ToolUsageStore: ToolUsageRecording {
    /// Process-wide store on the default path. Every gateway session shares it
    /// so they log into one file (one actor → no write races).
    static let shared = ToolUsageStore()

    private let storeURL: URL
    private let now: @Sendable () -> Date
    private var entries: [String: ToolUsage]
    private var loaded = false

    init(storeURL: URL = ToolUsageStore.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storeURL = storeURL
        self.now = now
        self.entries = [:]
    }

    func record(_ exposedName: String) async {
        loadIfNeeded()
        var entry = entries[exposedName] ?? ToolUsage(count: 0, lastUsedAt: now())
        entry.count += 1
        entry.lastUsedAt = now()
        entries[exposedName] = entry
        persist()
    }

    func snapshot() async -> [String: ToolUsage] {
        loadIfNeeded()
        return entries
    }

    // MARK: - Persistence

    static var defaultURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return support
            .appendingPathComponent("Ghostwire", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("tool-usage.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: ToolUsage].self, from: data) {
            entries = decoded
        }
        // Corrupt/unreadable → stay empty; writes still proceed.
    }

    private func persist() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
