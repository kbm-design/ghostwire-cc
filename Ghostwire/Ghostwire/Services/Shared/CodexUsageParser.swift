//
//  CodexUsageParser.swift
//  Ghostwire
//
//  GW-151: parses Codex rollout token_count events into a usage snapshot.
//  Pure + injectable-root (mirrors CodexTranscriptParser) so it's
//  fixture-testable; CodexUsageService owns polling/caching on top.
//
//  Mode detection: the LATEST token_count event across all sessions decides -
//  rate_limits non-null = ChatGPT-subscription auth (quota mode), null =
//  API-key auth (token mode). Verified on-disk 2026-06-03/04: apikey sessions
//  log rate_limits: null every event; 2025 subscription sessions log
//  primary (~5H) / secondary (~7D) used_percent + resets_in_seconds.
//

import Foundation

struct CodexUsageParser {
    /// Root of the Codex rollout tree (~/.codex/sessions), injectable for tests
    let sessionsRoot: String

    init(sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions") {
        self.sessionsRoot = sessionsRoot
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse all rollouts in the trailing 7-day window into one snapshot.
    func snapshot(now: Date) -> CodexUsageSnapshot {
        var snapshot = CodexUsageSnapshot()
        var latestEventDate = Date.distantPast

        for file in recentRolloutFiles(now: now) {
            guard let session = parseSessionFile(at: file) else { continue }

            snapshot.tokens += session.totals
            snapshot.tokensByModel[session.model ?? "unknown", default: .zero] += session.totals

            // Latest token_count across ALL sessions decides the auth mode
            // and the context gauge
            if session.eventDate > latestEventDate {
                latestEventDate = session.eventDate
                snapshot.rateLimits = session.rateLimits
                snapshot.lastContextUsed = session.lastContextUsed
                snapshot.modelContextWindow = session.modelContextWindow
            }
        }

        return snapshot
    }

    // MARK: - File discovery

    /// Rollout files in day-shards within the trailing 7-day window.
    /// Day granularity: a day-dir is included when its UTC midnight is on or
    /// after the window start's day - whole-day over-inclusion is fine.
    private func recentRolloutFiles(now: Date) -> [String] {
        let fileManager = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let windowStartDay = calendar.startOfDay(for: now.addingTimeInterval(-7 * 24 * 3600))

        func subdirs(_ path: String) -> [String] {
            (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        }

        var files: [String] = []
        for year in subdirs(sessionsRoot) {
            guard let y = Int(year) else { continue }
            let yearPath = sessionsRoot + "/" + year
            for month in subdirs(yearPath) {
                guard let m = Int(month) else { continue }
                let monthPath = yearPath + "/" + month
                for day in subdirs(monthPath) {
                    guard let d = Int(day),
                          let dayDate = calendar.date(from: DateComponents(year: y, month: m, day: d)),
                          dayDate >= windowStartDay else { continue }
                    let dayPath = monthPath + "/" + day
                    for file in subdirs(dayPath)
                    where file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") {
                        files.append(dayPath + "/" + file)
                    }
                }
            }
        }
        return files
    }

    // MARK: - Per-session parse

    private struct SessionUsage {
        /// Latest cumulative total_token_usage (cumulative WITHIN a session -
        /// summing every event would double-count)
        var totals: TokenUsageTotals
        var model: String?
        var eventDate: Date
        var rateLimits: AgentRateLimits?
        var lastContextUsed: Int?
        var modelContextWindow: Int?
    }

    /// Read a rollout and reduce it to the latest token_count + model.
    /// Returns nil when the file has no token_count events (pre-first-turn
    /// or chat-only sessions).
    private func parseSessionFile(at path: String) -> SessionUsage? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var usage: SessionUsage?
        var model: String?

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }

            switch json["type"] as? String {
            case "turn_context":
                if let m = payload["model"] as? String { model = m }

            case "event_msg" where payload["type"] as? String == "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any] else { continue }

                let eventDate = (json["timestamp"] as? String)
                    .flatMap { Self.isoFormatter.date(from: $0) } ?? Date.distantPast

                usage = SessionUsage(
                    totals: Self.parseTotals(totalUsage),
                    model: nil,  // attributed below from the session's last turn_context
                    eventDate: eventDate,
                    rateLimits: Self.parseRateLimits(payload["rate_limits"], eventDate: eventDate),
                    lastContextUsed: (info["last_token_usage"] as? [String: Any])
                        .flatMap { $0["total_tokens"] as? Int },
                    modelContextWindow: info["model_context_window"] as? Int
                )

            default:
                continue
            }
        }

        usage?.model = model
        return usage
    }

    private static func parseTotals(_ dict: [String: Any]) -> TokenUsageTotals {
        TokenUsageTotals(
            inputTokens: dict["input_tokens"] as? Int ?? 0,
            cachedInputTokens: dict["cached_input_tokens"] as? Int ?? 0,
            outputTokens: dict["output_tokens"] as? Int ?? 0,
            reasoningOutputTokens: dict["reasoning_output_tokens"] as? Int ?? 0
        )
    }

    /// rate_limits → AgentRateLimits. resetsAt anchors to the event timestamp
    /// (resets_in_seconds is relative to when Codex logged the event, not to
    /// when we parse it).
    private static func parseRateLimits(_ value: Any?, eventDate: Date) -> AgentRateLimits? {
        guard let dict = value as? [String: Any] else { return nil }

        func period(_ window: Any?) -> QuotaPeriod? {
            guard let w = window as? [String: Any],
                  let usedPercent = w["used_percent"] as? Double else { return nil }
            let resetsAt = (w["resets_in_seconds"] as? Double).map { eventDate.addingTimeInterval($0) }
            return QuotaPeriod(utilization: usedPercent, resetsAt: resetsAt)
        }

        let limits = AgentRateLimits(
            fiveHour: period(dict["primary"]),
            sevenDay: period(dict["secondary"])
        )
        return (limits.fiveHour == nil && limits.sevenDay == nil) ? nil : limits
    }
}
