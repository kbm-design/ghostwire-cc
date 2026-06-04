//
//  AlertHistoryStore.swift
//  Ghostwire
//
//  Records the alerts the app actually raised (passive permission glow,
//  ready-for-input sound) so GW-139's history list has a governed store
//  to render. Capped by the GW-144 settings: max entries + max age days.
//  No viewer UI here — recording + pruning + persistence only.
//

import Defaults
import Foundation

struct AgentAlert: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// AgentIdentity key ("claude" | "codex" | …); nil if unknown.
    let agent: String?
    let sessionId: String?
    /// "permission" | "ready" (string for forward-compat in the JSON).
    let kind: String
    /// Optional short context, e.g. the pending tool name.
    let detail: String?
}

@MainActor
final class AlertHistoryStore: ObservableObject {
    static let shared = AlertHistoryStore()

    @Published private(set) var alerts: [AgentAlert] = []

    private let fileURL: URL
    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("alert-history.json")

    init(fileURL: URL = AlertHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func record(agent: String?, sessionId: String?, kind: String, detail: String? = nil) {
        alerts.append(AgentAlert(
            id: UUID(),
            date: Date(),
            agent: agent,
            sessionId: sessionId,
            kind: kind,
            detail: detail
        ))
        prune()
        save()
    }

    func clear() {
        alerts = []
        save()
    }

    // MARK: - Pruning

    /// Newest `maxEntries` alerts no older than `maxAge`, oldest-first.
    /// Pure — unit-tested directly.
    nonisolated static func pruned(
        _ alerts: [AgentAlert],
        maxEntries: Int,
        maxAge: TimeInterval,
        now: Date
    ) -> [AgentAlert] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = alerts
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
        return Array(fresh.suffix(max(0, maxEntries)))
    }

    private func prune() {
        alerts = Self.pruned(
            alerts,
            maxEntries: Defaults[.alertHistoryMaxEntries],
            maxAge: TimeInterval(Defaults[.alertHistoryMaxAgeDays]) * 86_400,
            now: Date()
        )
    }

    // MARK: - Persistence (JSON next to the shelf's items.json)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder.alertHistory.decode([AgentAlert].self, from: data) else {
            return
        }
        alerts = stored
        prune()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder.alertHistory.encode(alerts) {
            try? data.write(to: fileURL)
        }
    }
}

private extension JSONDecoder {
    static let alertHistory: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let alertHistory: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
