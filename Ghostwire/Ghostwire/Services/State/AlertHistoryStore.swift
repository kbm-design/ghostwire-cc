//
//  AlertHistoryStore.swift
//  Ghostwire
//
//  Records the alerts the app actually raised (passive permission glow,
//  ready-for-input sound) so GW-139's history list has a governed store
//  to render. Capped by the GW-144 settings: max entries + max age days.
//  No viewer UI here — recording + pruning + persistence only.
//
//  Persists to ~/.ghostwire/alert-history.json (the app's dot-dir; the
//  shelf keeps its own store under Application Support). Writes are
//  atomic and run off the main actor; corrupt entries are salvaged
//  per-item rather than discarding the whole file (review F7/F9).
//

import Combine
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
    private var limitsCancellable: AnyCancellable?
    /// Serial queue keeps writes ordered while off the main actor (F9).
    /// Internal so tests can drain it (`ioQueue.sync {}`).
    static let ioQueue = DispatchQueue(label: "com.ghostwire.alert-history-io", qos: .utility)

    private static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ghostwire")
        .appendingPathComponent("alert-history.json")

    init(fileURL: URL = AlertHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()

        // Lowering the caps in settings prunes immediately (review M4),
        // not just on the next record().
        limitsCancellable = Defaults.publisher(keys: .alertHistoryMaxEntries, .alertHistoryMaxAgeDays)
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyLimits() }
            }
    }

    /// Touch the singleton at launch so first-alert recording doesn't pay
    /// the load() disk read on the animation path (review F9).
    func warm() {}

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

    /// Re-apply the configured caps; persists only when something fell out.
    func applyLimits() {
        let before = alerts.count
        prune()
        if alerts.count != before {
            save()
        }
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

    // MARK: - Persistence

    /// Wrapper that swallows undecodable entries so one corrupt item
    /// doesn't discard the whole history (review F7; shelf pattern).
    private struct SalvagedAlert: Decodable {
        let value: AgentAlert?
        init(from decoder: Decoder) {
            value = try? AgentAlert(from: decoder)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let salvaged = try? Self.decoder.decode([SalvagedAlert].self, from: data) else {
            return
        }
        let stored = salvaged.compactMap(\.value)
        alerts = stored
        prune()
        // Write back when load dropped anything (corrupt items or entries
        // over the caps) so disk reflects the enforced limits (review F6).
        if alerts.count != stored.count || stored.count != salvaged.count {
            save()
        }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(alerts) else { return }
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
