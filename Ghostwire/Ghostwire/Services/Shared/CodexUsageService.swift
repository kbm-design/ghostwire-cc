//
//  CodexUsageService.swift
//  Ghostwire
//
//  GW-151: Codex-side usage meter service, mirroring UsageService's poll
//  cadence. All data is local (rollout JSONLs + auth.json) - no network,
//  so no on-disk cache is needed; every poll reparses the 7-day window
//  (capped by CodexUsageParser's mtime/day-shard filtering).
//

import Combine
import Foundation

@MainActor
final class CodexUsageService: ObservableObject {
    static let shared = CodexUsageService()

    @Published private(set) var display: AgentUsageDisplay?
    /// Mtime of the newest rollout - AgentsTabView shows the Codex meter only
    /// when there's a live session or activity within the current 5H window.
    @Published private(set) var lastActivityDate: Date?

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 300

    private let parser: CodexUsageParser
    private let authJSONPath: String

    private init(
        parser: CodexUsageParser = CodexUsageParser(),
        authJSONPath: String = NSHomeDirectory() + "/.codex/auth.json"
    ) {
        self.parser = parser
        self.authJSONPath = authJSONPath
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        poll()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        let parser = self.parser
        let authJSONPath = self.authJSONPath

        pollTask = Task {
            // File IO off the main actor. GW-203: one scan yields both the
            // display and the activity signal (snapshot.latestActivity) - no
            // second mtime-walk of the rollout tree.
            let result: (display: AgentUsageDisplay?, activity: Date?) =
                await Task.detached(priority: .utility) {
                    let snapshot = parser.snapshot(now: Date())
                    let authMode = Self.readAuthMode(path: authJSONPath)
                    return (
                        Self.makeDisplay(snapshot: snapshot, authMode: authMode),
                        snapshot.latestActivity
                    )
                }.value

            guard !Task.isCancelled else { return }
            display = result.display
            lastActivityDate = result.activity
            scheduleNextPoll()
        }
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    // MARK: - Display selection

    /// Auth-branched display selection (pure - tested in
    /// AgentUsageDisplayTests). Quota mode needs BOTH signals: the latest
    /// token_count carried rate_limits AND auth.json isn't apikey -
    /// auth.json flips immediately on login changes, rollout events can lag.
    nonisolated static func makeDisplay(snapshot: CodexUsageSnapshot, authMode: String?) -> AgentUsageDisplay? {
        guard snapshot.hasData else { return nil }

        if let limits = snapshot.rateLimits, authMode != "apikey" {
            return .quota(fiveHour: limits.fiveHour, sevenDay: limits.sevenDay)
        }

        return .tokens(AgentTokenDisplay(
            sevenDay: snapshot.tokens,
            estimatedCostUSD: AgentCostTable.estimateUSD(tokensByModel: snapshot.tokensByModel),
            contextUsed: snapshot.lastContextUsed,
            contextWindow: snapshot.modelContextWindow
        ))
    }

    // MARK: - Auth detection

    nonisolated private static func readAuthMode(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["auth_mode"] as? String
    }
}
