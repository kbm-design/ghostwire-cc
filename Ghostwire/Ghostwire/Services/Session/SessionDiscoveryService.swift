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
    private let maxAge: TimeInterval
    private let rescanInterval: TimeInterval
    private let isAgentProcessAlive: @Sendable (String) -> Bool
    private let openCodexRolloutPaths: @Sendable () -> [String]

    /// Periodic rescan loop (nil when not started)
    private var rescanTask: Task<Void, Never>?

    init(
        claudeProjectsRoot: String = NSHomeDirectory() + "/.claude/projects",
        // GW-203: the GW-199 idle threshold, owned by AgentActivity.window.
        // Caps stale-provisional noise; a >5h-idle Claude session reappears on
        // its next transcript write or hook event. (Codex ignores this —
        // open-fd liveness is exact.)
        maxAge: TimeInterval = AgentActivity.window,
        rescanInterval: TimeInterval = 5 * 60,
        isAgentProcessAlive: @escaping @Sendable (String) -> Bool = SessionDiscoveryService.defaultProcessGate,
        openCodexRolloutPaths: @escaping @Sendable () -> [String] = SessionDiscoveryService.defaultOpenCodexRolloutPaths
    ) {
        self.claudeProjectsRoot = claudeProjectsRoot
        self.maxAge = maxAge
        self.rescanInterval = rescanInterval
        self.isAgentProcessAlive = isAgentProcessAlive
        self.openCodexRolloutPaths = openCodexRolloutPaths
    }

    // MARK: - Lifecycle

    /// Scan immediately, then rescan every `rescanInterval`: sessions whose
    /// hooks are silently broken still appear, and provisionals whose
    /// transcript aged out (or whose agent CLI exited) are pruned.
    func start() {
        guard rescanTask == nil else { return }
        rescanTask = Task {
            while !Task.isCancelled {
                let snapshot = discoverSessions()
                Self.logger.info("Discovery scan found \(snapshot.count) session(s)")
                await SessionStore.shared.process(.sessionsDiscovered(snapshot))
                try? await Task.sleep(nanoseconds: UInt64(rescanInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
    }

    // MARK: - Scanning

    /// One complete scan. The result is a full snapshot: callers may treat
    /// absence as "no longer discoverable".
    ///
    /// Claude liveness is approximate (mtime window + agent-global gate):
    /// claude appends-and-closes per transcript write, so no fd correlation
    /// is possible. Codex liveness is exact: codex CLIs hold their rollout
    /// open for the session's lifetime, so the open-fd set IS the live set.
    func discoverSessions(now: Date = Date()) -> [DiscoveredSession] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var sessions: [DiscoveredSession] = []

        if isAgentProcessAlive("claude") {
            sessions += discoverClaudeSessions(cutoff: cutoff)
        }
        sessions += discoverCodexSessions()

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

    /// Codex: a session is live iff a live codex process holds its rollout
    /// fd (rollout-<ts>-<uuid>.jsonl). No mtime window — an idle-for-days
    /// session with a held fd is live, and a fresh rollout with no holder is
    /// dead. cwd lives in the session_meta first line; a rollout without one
    /// can't produce a useful session row, so it's skipped.
    private func discoverCodexSessions() -> [DiscoveredSession] {
        var seenIds = Set<String>()
        var sessions: [DiscoveredSession] = []

        for path in openCodexRolloutPaths() {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }

            // UUIDs are fixed-width 36 chars right before ".jsonl"
            let stem = name.dropLast(".jsonl".count)
            guard stem.count > 36 else { continue }
            let sessionId = String(stem.suffix(36))
            guard UUID(uuidString: sessionId) != nil else { continue }

            // One line per fd in lsof output - several fds (or processes)
            // can hold the same rollout
            guard !seenIds.contains(sessionId) else { continue }

            guard let modified = regularFileModificationDate(path) else { continue }
            guard let cwd = codexCwd(rolloutPath: path) else { continue }

            seenIds.insert(sessionId)
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

    /// Rollout files currently held open by live codex CLI processes —
    /// the exact per-session liveness signal (verified empirically: codex
    /// keeps its rollout fd for the session's lifetime; claude does not,
    /// which is why Claude discovery can't use this).
    @Sendable static func defaultOpenCodexRolloutPaths() -> [String] {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let pids = tree.values
            .filter { $0.tty != nil && ($0.command as NSString).lastPathComponent == "codex" }
            .map { String($0.pid) }
        guard !pids.isEmpty else { return [] }

        // -Fn: machine-readable, one "n<path>" line per open file
        guard let output = ProcessExecutor.shared.runSyncOrNil(
            "/usr/sbin/lsof",
            arguments: ["-p", pids.joined(separator: ","), "-Fn"]
        ) else {
            return []
        }

        return output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
            .filter { path in
                path.hasSuffix(".jsonl")
                    && (path as NSString).lastPathComponent.hasPrefix("rollout-")
            }
    }
}
