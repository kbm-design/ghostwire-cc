//
//  SessionDiscoveryService.swift
//  Ghostwire
//
//  GW-194: launch-time session discovery. Scans the Claude and Codex
//  transcript trees for recently-modified session files so already-running
//  (or idle) agent sessions appear in the notch without waiting for a hook
//  event that may never come.
//

import Foundation
import os

/// A session transcript found on disk before any hook event arrived (GW-194)
struct DiscoveredSession: Equatable, Sendable {
    let sessionId: String
    let cwd: String
    /// "claude" | "codex" — same values as HookEvent.source
    let agent: String
    let transcriptPath: String
    let fileModified: Date
}

actor SessionDiscoveryService {
    static let shared = SessionDiscoveryService()

    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "Discovery")

    private let claudeProjectsRoot: String
    private let codexSessionsRoot: String
    private let maxAge: TimeInterval
    private let isAgentProcessAlive: @Sendable (String) -> Bool

    init(
        claudeProjectsRoot: String = NSHomeDirectory() + "/.claude/projects",
        codexSessionsRoot: String = NSHomeDirectory() + "/.codex/sessions",
        maxAge: TimeInterval = 24 * 3600,
        isAgentProcessAlive: @escaping @Sendable (String) -> Bool = SessionDiscoveryService.defaultProcessGate
    ) {
        self.claudeProjectsRoot = claudeProjectsRoot
        self.codexSessionsRoot = codexSessionsRoot
        self.maxAge = maxAge
        self.isAgentProcessAlive = isAgentProcessAlive
    }

    // MARK: - Scanning

    /// One complete scan of both transcript trees. The result is a full
    /// snapshot: callers may treat absence as "no longer discoverable".
    func discoverSessions(now: Date = Date()) -> [DiscoveredSession] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var sessions: [DiscoveredSession] = []

        if isAgentProcessAlive("claude") {
            sessions += discoverClaudeSessions(cutoff: cutoff)
        }
        if isAgentProcessAlive("codex") {
            sessions += discoverCodexSessions(cutoff: cutoff)
        }

        return sessions
    }

    /// Claude: ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl
    /// Project dirs also hold agent-<id>.jsonl subagent transcripts and bare
    /// UUID-named sidecar directories — only UUID-named regular files count.
    private func discoverClaudeSessions(cutoff: Date) -> [DiscoveredSession] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: claudeProjectsRoot) else {
            return []
        }

        var sessions: [DiscoveredSession] = []
        for projectDir in projectDirs {
            let dirPath = claudeProjectsRoot + "/" + projectDir
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dirPath) else { continue }

            for entry in entries where entry.hasSuffix(".jsonl") {
                let sessionId = String(entry.dropLast(".jsonl".count))
                guard UUID(uuidString: sessionId) != nil else { continue }

                let path = dirPath + "/" + entry
                guard let modified = regularFileModificationDate(path), modified >= cutoff else { continue }

                let cwd = claudeCwd(transcriptPath: path) ?? decodeProjectDirName(projectDir)
                sessions.append(DiscoveredSession(
                    sessionId: sessionId,
                    cwd: cwd,
                    agent: "claude",
                    transcriptPath: path,
                    fileModified: modified
                ))
            }
        }
        return sessions
    }

    /// Codex: ~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<uuid>.jsonl
    /// cwd lives in the session_meta first line; a rollout without one can't
    /// produce a useful session row, so it's skipped.
    private func discoverCodexSessions(cutoff: Date) -> [DiscoveredSession] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: codexSessionsRoot) else { return [] }

        var sessions: [DiscoveredSession] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }

            // UUIDs are fixed-width 36 chars right before ".jsonl"
            let stem = name.dropLast(".jsonl".count)
            guard stem.count > 36 else { continue }
            let sessionId = String(stem.suffix(36))
            guard UUID(uuidString: sessionId) != nil else { continue }

            let path = codexSessionsRoot + "/" + relative
            guard let modified = regularFileModificationDate(path), modified >= cutoff else { continue }
            guard let cwd = codexCwd(rolloutPath: path) else { continue }

            sessions.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                agent: "codex",
                transcriptPath: path,
                fileModified: modified
            ))
        }
        return sessions
    }

    // MARK: - cwd resolution

    /// First "cwd" value in the transcript's leading lines. The first lines
    /// are often metadata without one (summary, last-prompt, mode), so scan a
    /// bounded head of the file rather than just line 1.
    private func claudeCwd(transcriptPath: String) -> String? {
        for json in headJSONLines(path: transcriptPath, maxLines: 25) {
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
        }
        return nil
    }

    /// payload.cwd from the session_meta line (line 1 in practice; scan the
    /// head defensively).
    private func codexCwd(rolloutPath: String) -> String? {
        for json in headJSONLines(path: rolloutPath, maxLines: 5) {
            guard json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// Decode ~/.claude/projects dirname back to a path. Lossy by
    /// construction ("/" and "." both encode to "-") — content cwd wins
    /// whenever present; this is the fallback for transcripts that carry none.
    private func decodeProjectDirName(_ dirName: String) -> String {
        dirName.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - File helpers

    /// Modification date, but only for regular files (project dirs contain
    /// UUID-named sidecar directories that must not register as sessions).
    private func regularFileModificationDate(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Parse up to maxLines leading JSONL lines from a bounded head read —
    /// transcripts grow to many MB and the cwd always sits near the top.
    private func headJSONLines(path: String, maxLines: Int) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: 64 * 1024) else {
            return []
        }
        defer { try? handle.close() }

        guard let head = String(data: data, encoding: .utf8) else { return [] }

        var lines: [[String: Any]] = []
        for line in head.components(separatedBy: "\n").prefix(maxLines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            lines.append(json)
        }
        return lines
    }

    // MARK: - Process gate

    /// Whether any CLI process for the agent is alive. Requires a tty: the
    /// Codex desktop app ships a binary literally named "codex" (and Claude's
    /// app one named "Claude"), but rollout/projects transcripts only come
    /// from CLI sessions, which always hold a tty.
    @Sendable static func defaultProcessGate(agent: String) -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        return tree.values.contains { info in
            info.tty != nil && (info.command as NSString).lastPathComponent == agent
        }
    }
}
