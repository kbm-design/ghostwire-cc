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
import os

actor CodexTranscriptParser {
    static let shared = CodexTranscriptParser()

    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "CodexParser")

    /// Root of the Codex rollout tree (injectable for tests)
    private let sessionsRoot: String

    /// sessionId -> resolved rollout file path
    private var pathCache: [String: String] = [:]

    /// rollout path -> cached parse keyed by file modification date
    private var infoCache: [String: (modificationDate: Date, info: ConversationInfo)] = [:]

    init(sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions") {
        self.sessionsRoot = sessionsRoot
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
                        return fullPath
                    }
                }
            }
        }

        return nil
    }

    // MARK: - ConversationInfo (title / preview)

    /// Parse rollout into ConversationInfo (cached by file modification date).
    /// summary stays nil — Codex has no ai-title equivalent, so the UI falls
    /// back to firstUserMessage, same as a Claude session without a title.
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

        let info = ConversationInfo(
            summary: nil,
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
        guard let path = rolloutFilePath(sessionId: sessionId),
              let data = FileManager.default.contents(atPath: path),
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

        return CodexConversation(
            messages: messages,
            completedToolIds: completedToolIds,
            toolResults: toolResults
        )
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
