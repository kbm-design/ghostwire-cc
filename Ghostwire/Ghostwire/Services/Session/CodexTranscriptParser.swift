//
//  CodexTranscriptParser.swift
//  Ghostwire
//
//  GW-191: parses Codex rollout transcripts so Codex sessions get the same
//  title / preview / conversation history as Claude sessions in the notch.
//
//  Codex transcripts live at ~/.codex/sessions/<Y>/<M>/<D>/
//  rollout-<timestamp>-<sessionUUID>.jsonl with a line schema of
//  { timestamp, type, payload } where type is one of:
//    - session_meta   (session id, cwd, cli version)
//    - event_msg      (payload.type: user_message / agent_message /
//                      task_started / task_complete / token_count)
//    - response_item  (payload.type: message / function_call /
//                      function_call_output / reasoning)
//    - turn_context
//
//  event_msg carries the clean user/agent text (response_item user messages
//  include injected AGENTS.md instructions); function_call(+output) carries
//  tool executions keyed by call_id.
//

import Foundation
import SQLite3
import os

actor CodexTranscriptParser {
    static let shared = CodexTranscriptParser()

    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "CodexParser")

    /// Root of the Codex rollout tree (injectable for tests)
    private let sessionsRoot: String

    /// How long a failed path resolution suppresses re-walking the tree.
    /// Rollout files are created lazily on the session's first turn, so a brand-new
    /// session misses on every hook event - without this, each miss re-walks the
    /// entire (potentially multi-hundred-file) sessions tree.
    private let negativeCacheTTL: TimeInterval

    /// sessionId -> resolved rollout file path
    private var pathCache: [String: String] = [:]

    /// sessionId -> time of last failed resolution (negative cache)
    private var missCache: [String: Date] = [:]

    /// rollout path -> cached parse keyed by file modification date
    private var infoCache: [String: (modificationDate: Date, info: ConversationInfo)] = [:]

    /// rollout path -> cached full conversation keyed by file modification date
    private var conversationCache: [String: (modificationDate: Date, conversation: CodexConversation)] = [:]

    /// Codex's sqlite index over rollouts (threads table: id, rollout_path, title)
    private let stateDBPath: String

    init(
        sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions",
        stateDBPath: String = NSHomeDirectory() + "/.codex/state_5.sqlite",
        negativeCacheTTL: TimeInterval = 5
    ) {
        self.sessionsRoot = sessionsRoot
        self.stateDBPath = stateDBPath
        self.negativeCacheTTL = negativeCacheTTL
    }

    // MARK: - Codex thread index (state_5.sqlite)

    /// Read (title, rollout_path) for a session from Codex's own sqlite index.
    /// GW-197: titles are set once by the launching surface (desktop app, Codex
    /// Companion, computer-use) and exist ONLY here, not in the rollout JSONL.
    /// Read-only open; returns nil whenever the db is missing, locked, or has
    /// no row (pre-first-turn sessions - rollouts and thread rows are lazy).
    private func threadIndexEntry(sessionId: String) -> (title: String?, rolloutPath: String?)? {
        guard FileManager.default.fileExists(atPath: stateDBPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(stateDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT title, rollout_path FROM threads WHERE id = ?1 LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionId, -1, transient)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let title = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        let rolloutPath = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        return (
            title: (title?.isEmpty == false) ? title : nil,
            rolloutPath: (rolloutPath?.isEmpty == false) ? rolloutPath : nil
        )
    }

    /// A parsed Codex conversation: history plus tool completion state
    struct CodexConversation {
        let messages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]

        static let empty = CodexConversation(messages: [], completedToolIds: [], toolResults: [:])
    }

    // MARK: - Path resolution

    /// Locate the rollout file for a session UUID.
    /// Files are sharded by date (Y/M/D), so walk newest-first and cache the hit.
    func rolloutFilePath(sessionId: String) -> String? {
        if let cached = pathCache[sessionId],
           FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        // Negative cache: don't re-walk the tree for a session we just failed
        // to resolve (pre-first-turn sessions miss on every hook event)
        if let lastMiss = missCache[sessionId],
           Date().timeIntervalSince(lastMiss) < negativeCacheTTL {
            return nil
        }

        // Codex's own index is authoritative and O(1) - prefer it over the walk
        if let indexed = threadIndexEntry(sessionId: sessionId)?.rolloutPath,
           FileManager.default.fileExists(atPath: indexed) {
            pathCache[sessionId] = indexed
            missCache.removeValue(forKey: sessionId)
            return indexed
        }

        let fileManager = FileManager.default
        let suffix = "-\(sessionId).jsonl"

        func sortedSubdirs(_ path: String) -> [String] {
            (try? fileManager.contentsOfDirectory(atPath: path))?
                .sorted(by: >) ?? []
        }

        for year in sortedSubdirs(sessionsRoot) {
            let yearPath = sessionsRoot + "/" + year
            for month in sortedSubdirs(yearPath) {
                let monthPath = yearPath + "/" + month
                for day in sortedSubdirs(monthPath) {
                    let dayPath = monthPath + "/" + day
                    for file in sortedSubdirs(dayPath) where file.hasSuffix(suffix) {
                        let fullPath = dayPath + "/" + file
                        pathCache[sessionId] = fullPath
                        missCache.removeValue(forKey: sessionId)
                        return fullPath
                    }
                }
            }
        }

        missCache[sessionId] = Date()
        return nil
    }

    // MARK: - ConversationInfo (title / preview)

    /// Parse rollout into ConversationInfo (cached by file modification date).
    /// summary comes from Codex's sqlite thread index when the launching surface
    /// set one (GW-197); otherwise nil and the UI falls back to firstUserMessage,
    /// same as Codex's own default.
    func parse(sessionId: String) -> ConversationInfo {
        let empty = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )

        guard let path = rolloutFilePath(sessionId: sessionId) else { return empty }

        let fileManager = FileManager.default
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return empty
        }

        if let cached = infoCache[path], cached.modificationDate == modDate {
            return cached.info
        }

        guard let data = fileManager.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return empty
        }

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var lastUserMessageDate: Date?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else {
                continue
            }

            let lineType = json["type"] as? String
            let payloadType = payload["type"] as? String

            if lineType == "event_msg" {
                if payloadType == "user_message", let message = payload["message"] as? String {
                    if firstUserMessage == nil {
                        firstUserMessage = Self.truncate(message, maxLength: 50)
                    }
                    lastMessage = message
                    lastMessageRole = "user"
                    lastToolName = nil
                    if let timestampStr = json["timestamp"] as? String {
                        lastUserMessageDate = formatter.date(from: timestampStr)
                    }
                } else if payloadType == "agent_message", let message = payload["message"] as? String {
                    lastMessage = message
                    lastMessageRole = "assistant"
                    lastToolName = nil
                }
            } else if lineType == "response_item", payloadType == "function_call" {
                let name = payload["name"] as? String ?? "Tool"
                // Input preview ONLY - the UI renders lastToolName next to
                // lastMessage, so including the name here doubles it ("get get")
                lastMessage = ToolUseBlock(
                    id: "",
                    name: name,
                    input: Self.parseArguments(payload["arguments"] as? String)
                ).preview
                lastMessageRole = "tool"
                lastToolName = name
            }
        }

        // Title from Codex's sqlite index (GW-197) - set by the launching
        // surface; nil falls back to firstUserMessage in the UI, matching
        // Codex's own default
        let title = threadIndexEntry(sessionId: sessionId)?.title

        let info = ConversationInfo(
            summary: title,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
        infoCache[path] = (modificationDate: modDate, info: info)
        return info
    }

    // MARK: - Conversation history

    /// Parse the full conversation: user/agent text from event_msg, tool calls
    /// from response_item function_call(+output). Message ids are derived from
    /// line numbers (stable across reparses — rollout files are append-only).
    func parseConversation(sessionId: String) -> CodexConversation {
        guard let path = rolloutFilePath(sessionId: sessionId) else { return .empty }

        // Cache by modification date - synced on every hook event, and rollouts
        // grow to many MB on long sessions
        let modDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let modDate, let cached = conversationCache[path], cached.modificationDate == modDate {
            return cached.conversation
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return .empty
        }

        var messages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fallbackDate = Date.distantPast

        let idPrefix = "codex-\(sessionId.prefix(8))"

        for (lineIndex, line) in content.components(separatedBy: "\n").enumerated() where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else {
                continue
            }

            let lineType = json["type"] as? String
            let payloadType = payload["type"] as? String

            var timestamp = fallbackDate
            if let timestampStr = json["timestamp"] as? String,
               let parsed = formatter.date(from: timestampStr) {
                timestamp = parsed
                fallbackDate = parsed
            }

            if lineType == "event_msg" {
                if payloadType == "user_message", let message = payload["message"] as? String {
                    messages.append(ChatMessage(
                        id: "\(idPrefix)-line\(lineIndex)",
                        role: .user,
                        timestamp: timestamp,
                        content: [.text(message)]
                    ))
                } else if payloadType == "agent_message", let message = payload["message"] as? String {
                    messages.append(ChatMessage(
                        id: "\(idPrefix)-line\(lineIndex)",
                        role: .assistant,
                        timestamp: timestamp,
                        content: [.text(message)]
                    ))
                }
            } else if lineType == "response_item" {
                if payloadType == "function_call", let callId = payload["call_id"] as? String {
                    let name = payload["name"] as? String ?? "Tool"
                    messages.append(ChatMessage(
                        id: "\(idPrefix)-line\(lineIndex)",
                        role: .assistant,
                        timestamp: timestamp,
                        content: [.toolUse(ToolUseBlock(
                            id: callId,
                            name: name,
                            input: Self.parseArguments(payload["arguments"] as? String)
                        ))]
                    ))
                } else if payloadType == "function_call_output", let callId = payload["call_id"] as? String {
                    completedToolIds.insert(callId)
                    let output = payload["output"] as? String
                    toolResults[callId] = ConversationParser.ToolResult(
                        content: output, stdout: nil, stderr: nil, isError: false
                    )
                }
            }
        }

        let conversation = CodexConversation(
            messages: messages,
            completedToolIds: completedToolIds,
            toolResults: toolResults
        )
        if let modDate {
            conversationCache[path] = (modificationDate: modDate, conversation: conversation)
        }
        return conversation
    }

    // MARK: - Helpers

    /// Decode a function_call arguments JSON string into display strings.
    /// Codex's "cmd" is surfaced as "command" so ToolUseBlock.preview and the
    /// approval row render it like a Claude Bash command.
    private static func parseArguments(_ arguments: String?) -> [String: String] {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var input: [String: String] = [:]
        for (key, value) in json {
            let displayKey = key == "cmd" ? "command" : key
            switch value {
            case let str as String:
                input[displayKey] = str
            case let num as NSNumber:
                input[displayKey] = num.stringValue
            default:
                continue
            }
        }
        return input
    }

    private static func truncate(_ message: String, maxLength: Int) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        if firstLine.count <= maxLength {
            return firstLine
        }
        return String(firstLine.prefix(maxLength)) + "..."
    }
}
