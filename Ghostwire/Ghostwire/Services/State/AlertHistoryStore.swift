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

    // MARK: - GW-207 v2 fields
    // All optional + Codable: synthesized `init(from:)` uses
    // decodeIfPresent for optionals, so v1 JSON (which lacks these keys)
    // decodes cleanly with nil — verified by AlertHistoryStoreTests.

    /// Project dir last path component, captured at record time.
    let folder: String?
    /// Permission alerts: the command/tool input, single-line. nil for ready.
    let command: String?
    /// Resolved outcome: "allowed" | "denied" | "timedOut" | "responded".
    /// nil = unanswered (permission) or no user reply yet (ready).
    let outcome: String?
    /// tool_use_id of the pending permission, for outcome matching. nil for ready.
    let toolUseId: String?

    nonisolated init(
        id: UUID,
        date: Date,
        agent: String?,
        sessionId: String?,
        kind: String,
        detail: String?,
        folder: String? = nil,
        command: String? = nil,
        outcome: String? = nil,
        toolUseId: String? = nil
    ) {
        self.id = id
        self.date = date
        self.agent = agent
        self.sessionId = sessionId
        self.kind = kind
        self.detail = detail
        self.folder = folder
        self.command = command
        self.outcome = outcome
        self.toolUseId = toolUseId
    }

    /// Copy with a resolved outcome — alerts are immutable `let` structs.
    nonisolated func withOutcome(_ outcome: String) -> AgentAlert {
        AgentAlert(
            id: id, date: date, agent: agent, sessionId: sessionId,
            kind: kind, detail: detail, folder: folder, command: command,
            outcome: outcome, toolUseId: toolUseId
        )
    }
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

    func record(
        agent: String?,
        sessionId: String?,
        kind: String,
        detail: String? = nil,
        folder: String? = nil,
        command: String? = nil,
        toolUseId: String? = nil
    ) {
        alerts.append(AgentAlert(
            id: UUID(),
            date: Date(),
            agent: agent,
            sessionId: sessionId,
            kind: kind,
            detail: detail,
            folder: folder,
            command: command,
            toolUseId: toolUseId
        ))
        prune()
        save()
    }

    /// GW-207: stamp the outcome ("allowed"|"denied"|"timedOut") on the
    /// permission alert matching this verdict. Persists only on a change.
    func markPermissionOutcome(sessionId: String?, toolUseId: String?, outcome: String) {
        guard let updated = Self.applyingPermissionOutcome(
            to: alerts, sessionId: sessionId, toolUseId: toolUseId, outcome: outcome
        ) else { return }
        alerts = updated
        save()
    }

    /// GW-207: mark the most recent ready alert that predates `userMessageDate`
    /// as "responded" (a user message followed the ping). Persists on change.
    func markReadyResponded(sessionId: String?, userMessageDate: Date) {
        guard let updated = Self.applyingReadyResponded(
            to: alerts, sessionId: sessionId, before: userMessageDate
        ) else { return }
        alerts = updated
        save()
    }

    func clear() {
        alerts = []
        save()
    }

    // MARK: - Outcome matching (pure, unit-tested)

    /// Stamp `outcome` on the newest still-unresolved permission alert for this
    /// session + tool_use_id. Returns nil when nothing matches (no write). Only
    /// the single most-recent match is updated, never the whole history.
    nonisolated static func applyingPermissionOutcome(
        to alerts: [AgentAlert],
        sessionId: String?,
        toolUseId: String?,
        outcome: String
    ) -> [AgentAlert]? {
        guard let idx = alerts.lastIndex(where: {
            $0.kind == "permission"
                && $0.outcome == nil
                && $0.sessionId == sessionId
                && $0.toolUseId == toolUseId
        }) else { return nil }
        var copy = alerts
        copy[idx] = copy[idx].withOutcome(outcome)
        return copy
    }

    /// Mark the newest still-unanswered ready alert that was raised BEFORE the
    /// user message as "responded". A ready alert raised after the message
    /// stays unanswered (the user hasn't replied to *that* ping yet). nil = no write.
    nonisolated static func applyingReadyResponded(
        to alerts: [AgentAlert],
        sessionId: String?,
        before userMessageDate: Date
    ) -> [AgentAlert]? {
        guard let idx = alerts.lastIndex(where: {
            $0.kind == "ready"
                && $0.outcome == nil
                && $0.sessionId == sessionId
                && $0.date <= userMessageDate
        }) else { return nil }
        var copy = alerts
        copy[idx] = copy[idx].withOutcome("responded")
        return copy
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
