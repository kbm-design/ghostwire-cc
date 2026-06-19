//
//  WorkingSetSelector.swift
//  Ghostwire
//
//  GW-184: pick the ~25 downstream tools the gateway exposes directly. Pure —
//  takes the ordered tool catalog + a usage snapshot, returns the working-set
//  names. Everything not selected stays reachable via search_tools/call_tool.
//
//  Cold start (no usage yet): round-robin the catalog across servers so every
//  connected server is represented on day one. Warm: the N most-recent ∪ the M
//  most-frequent, deduped, recency first.
//

import Foundation

enum WorkingSetSelector {
    /// `catalog` is the exposed (namespaced) tool names in build order, paired
    /// with their owning server. Returns the working-set names, ordered.
    static func select(
        catalog: [(name: String, serverID: UUID)],
        usage: [String: ToolUsage],
        config: WorkingSetConfig
    ) -> [String] {
        let catalogNames = Set(catalog.map(\.name))
        let known = usage.filter { catalogNames.contains($0.key) }

        if known.isEmpty {
            return coldStart(catalog: catalog, cap: config.cap)
        }
        return warm(known: known, config: config)
    }

    // MARK: - Cold start

    /// Round-robin across servers (server order = first appearance in catalog),
    /// taking one tool per server per round until the cap is hit.
    private static func coldStart(catalog: [(name: String, serverID: UUID)], cap: Int) -> [String] {
        var order: [UUID] = []
        var buckets: [UUID: [String]] = [:]
        for entry in catalog {
            if buckets[entry.serverID] == nil { order.append(entry.serverID) }
            buckets[entry.serverID, default: []].append(entry.name)
        }

        var selected: [String] = []
        var round = 0
        let maxDepth = buckets.values.map(\.count).max() ?? 0
        while round < maxDepth && selected.count < cap {
            for serverID in order {
                guard selected.count < cap else { break }
                let bucket = buckets[serverID] ?? []
                if round < bucket.count { selected.append(bucket[round]) }
            }
            round += 1
        }
        return selected
    }

    // MARK: - Warm

    /// Recency (most-recent first, up to recencyLimit) ∪ frequency (most-used
    /// first, up to frequencyLimit), deduped, recency entries kept ahead.
    private static func warm(known: [String: ToolUsage], config: WorkingSetConfig) -> [String] {
        let recent = known
            .sorted { $0.value.lastUsedAt > $1.value.lastUsedAt }
            .prefix(config.recencyLimit)
            .map(\.key)
        let frequent = known
            .sorted { $0.value.count > $1.value.count }
            .prefix(config.frequencyLimit)
            .map(\.key)

        var seen = Set<String>()
        var result: [String] = []
        for name in recent + frequent where !seen.contains(name) {
            seen.insert(name)
            result.append(name)
            if result.count >= config.cap { break }
        }
        return result
    }
}
