//
//  ClaudeTokenUsageParser.swift
//  Ghostwire
//
//  GW-151: aggregates Claude transcript usage{} blocks for API-key auth
//  (no OAuth quota endpoint → token mode). Pure + injectable-root so it's
//  fixture-testable; UsageService owns auth detection/polling on top.
//

import Foundation

/// Claude API-token usage over the meter windows.
struct ClaudeTokenSnapshot: Equatable, Codable {
    var fiveHour: TokenUsageTotals = .zero
    var sevenDay: TokenUsageTotals = .zero
    /// 7D totals attributed per model (for cost estimation)
    var tokensByModel: [String: TokenUsageTotals] = [:]

    var hasData: Bool { sevenDay != .zero }
}

struct ClaudeTokenUsageParser {
    /// Root of the Claude transcript tree (~/.claude/projects), injectable for tests
    let projectsRoot: String

    init(projectsRoot: String = NSHomeDirectory() + "/.claude/projects") {
        self.projectsRoot = projectsRoot
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Aggregate assistant usage{} over the trailing 5H/7D windows.
    ///
    /// Dedupe is by message.id + requestId, global across files: transcripts
    /// repeat assistant lines (streaming updates; resumed sessions copy
    /// history into a new file) with identical usage - audited 2026-06-04 on
    /// this machine: 5172/7112 ids appeared >1x (max 16x). Summing naively
    /// would roughly double-count.
    func snapshot(now: Date) -> ClaudeTokenSnapshot {
        let sevenDayStart = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHourStart = now.addingTimeInterval(-5 * 3600)

        var snapshot = ClaudeTokenSnapshot()
        var seenMessages = Set<String>()

        for file in recentTranscriptFiles(notBefore: sevenDayStart) {
            guard let data = FileManager.default.contents(atPath: file),
                  let content = String(data: data, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "assistant",
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                // "<synthetic>" assistant lines are local error placeholders,
                // not billed API calls
                let model = message["model"] as? String ?? "unknown"
                guard model != "<synthetic>" else { continue }

                guard let timestampStr = json["timestamp"] as? String,
                      let timestamp = Self.isoFormatter.date(from: timestampStr),
                      timestamp >= sevenDayStart else { continue }

                let dedupeKey = "\(message["id"] as? String ?? "")|\(json["requestId"] as? String ?? "")"
                guard !seenMessages.contains(dedupeKey) else { continue }
                seenMessages.insert(dedupeKey)

                let totals = TokenUsageTotals(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    cachedInputTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                    cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0
                )

                snapshot.sevenDay += totals
                snapshot.tokensByModel[model, default: .zero] += totals
                if timestamp >= fiveHourStart {
                    snapshot.fiveHour += totals
                }
            }
        }

        return snapshot
    }

    /// GW-199: newest transcript mtime - the Claude-side activity signal
    /// (mirrors CodexUsageService.lastActivityDate for the idle rule).
    func newestTranscriptDate() -> Date? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: projectsRoot) else { return nil }

        var newest: Date?
        for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
            let path = projectsRoot + "/" + relative
            if let modDate = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               modDate > (newest ?? .distantPast) {
                newest = modDate
            }
        }
        return newest
    }

    /// All transcript files whose mtime falls inside the window - an
    /// untouched file can't contain in-window events, so skip opening it.
    private func recentTranscriptFiles(notBefore windowStart: Date) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: projectsRoot) else { return [] }

        var files: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".jsonl") {
            let path = projectsRoot + "/" + relative
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate >= windowStart else { continue }
            files.append(path)
        }
        return files
    }
}
