//
//  CursorTranscriptParser.swift
//  Ghostwire
//
//  Parses Cursor agent-transcript JSONL into the same ChatMessage shape the
//  Claude parser produces, so the notch chat surface renders Cursor sessions
//  without a second UI path (GW-311).
//
//  ⚠️ CURRENTLY UNWIRED (GW-311, 2026-07-27). Live Cursor chat is built from the
//  hook event stream (SessionStore.applyCursorHookChat), not this file — Cursor
//  writes its transcript lazily and often incompletely, so it is useless as a
//  live mirror. This parser is retained as a HISTORY-BACKFILL candidate: the
//  transcript IS eventually written, so it could populate chat when opening an
//  old Cursor session. Follow-up ticket tracks wiring-or-removal. Tests in
//  CursorTranscriptParserTests still exercise it against the real on-disk format.
//
//  Cursor's format (verified against ~/.cursor/projects/*/agent-transcripts,
//  2026-07): every line is `{"role": "user"|"assistant", "message": {"content": [...]}}`.
//  The content blocks are Claude-shaped (`text` / `tool_use`), but the envelope
//  is leaner than Claude's in four ways that this parser has to paper over:
//
//  1. No `uuid`      -> message ids are synthesised from the line index.
//  2. No `timestamp` -> timestamps are synthesised, anchored to the file's dates.
//  3. No `id` on `tool_use` blocks -> tool ids are synthesised from line/block index.
//  4. No `tool_result` blocks at all -> completion is inferred from position.
//
//  All four synthetics key off the line index, which is stable because the file
//  is append-only — a re-parse of the same line yields the same id, so the
//  incremental append path in SessionStore dedups correctly.
//

import Foundation
import os

actor CursorTranscriptParser {
    static let shared = CursorTranscriptParser()

    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "CursorParser")

    /// Incremental read state, keyed by session id
    private var incrementalState: [String: State] = [:]

    private struct State {
        var lastFileOffset: UInt64 = 0
        var lineIndex: Int = 0
        var messages: [ChatMessage] = []
        /// Every tool seen so far, in file order, with the line it came from —
        /// the line is what decides completion (see `completedToolIds`).
        var toolsInOrder: [(id: String, lineIndex: Int)] = []
        /// Ids already handed to the store as complete, so each is reported once.
        var reportedComplete: Set<String> = []
        /// Anchors synthesised timestamps to real wall-clock time.
        var baseDate: Date?
    }

    struct ParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        /// Tool ids treated as finished. Cursor's transcript carries no
        /// `tool_result`, so a `tool_use` is considered done once any later line
        /// exists — the agent demonstrably moved on. Only a trailing tool call
        /// stays `running`.
        let completedToolIds: Set<String>
        /// Tools that became complete during *this* parse. A tool is created as
        /// `running` while it is the newest one, so the store has to flip it
        /// later — the append path never revisits an existing item's status.
        let newlyCompletedToolIds: Set<String>
    }

    // MARK: - Incremental Parsing

    /// Parse only lines appended since the last call for this session.
    func parseIncremental(sessionId: String, transcriptPath: String) -> ParseResult {
        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return ParseResult(
                newMessages: [], allMessages: [],
                completedToolIds: [], newlyCompletedToolIds: []
            )
        }

        var state = incrementalState[sessionId] ?? State()
        let newMessages = parseNewLines(path: transcriptPath, sessionId: sessionId, state: &state)

        let completed = Self.completedToolIds(from: state)
        let newlyCompleted = completed.subtracting(state.reportedComplete)
        state.reportedComplete = completed

        incrementalState[sessionId] = state

        return ParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: completed,
            newlyCompletedToolIds: newlyCompleted
        )
    }

    /// A tool has demonstrably returned once the agent moved past it — either a
    /// later tool call exists, or a later line does. Only a tool sitting at the
    /// very end of the file, with nothing after it, is still running.
    private static func completedToolIds(from state: State) -> Set<String> {
        guard let last = state.toolsInOrder.last else { return [] }

        var completed = Set(state.toolsInOrder.dropLast().map(\.id))

        // Index of the newest line parsed so far (lineIndex is the next to assign).
        let lastLineIndex = state.lineIndex - 1
        if last.lineIndex < lastLineIndex {
            completed.insert(last.id)
        }
        return completed
    }

    /// Drop cached state for a session (reload / session end).
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    private func parseNewLines(path: String, sessionId: String, state: inout State) -> [ChatMessage] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return [] }

        // Truncated or replaced (new conversation reusing the id) -> start over.
        if fileSize < state.lastFileOffset {
            state = State()
        }
        if fileSize == state.lastFileOffset {
            return []
        }

        if state.baseDate == nil {
            state.baseDate = Self.anchorDate(path: path)
        }

        guard (try? handle.seek(toOffset: state.lastFileOffset)) != nil,
              let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var newMessages: [ChatMessage] = []
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            let index = state.lineIndex
            state.lineIndex += 1

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = parseLine(
                      json,
                      sessionId: sessionId,
                      lineIndex: index,
                      baseDate: state.baseDate ?? Date(),
                      toolsInOrder: &state.toolsInOrder
                  ) else {
                continue
            }

            newMessages.append(message)
            state.messages.append(message)
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    // MARK: - Line Parsing

    private func parseLine(
        _ json: [String: Any],
        sessionId: String,
        lineIndex: Int,
        baseDate: Date,
        toolsInOrder: inout [(id: String, lineIndex: Int)]
    ) -> ChatMessage? {
        guard let role = json["role"] as? String,
              role == "user" || role == "assistant",
              let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        var blocks: [MessageBlock] = []

        if let text = messageDict["content"] as? String {
            if let cleaned = Self.cleanUserText(text) {
                blocks.append(.text(cleaned))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for (blockIndex, block) in contentArray.enumerated() {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String,
                       let cleaned = Self.cleanUserText(text) {
                        blocks.append(.text(cleaned))
                    }
                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        blocks.append(.thinking(thinking))
                    }
                case "tool_use":
                    // Cursor omits `id` on tool blocks; synthesise a stable one.
                    let toolId = "cursor-\(sessionId)-\(lineIndex)-\(blockIndex)"
                    if let tool = Self.parseToolUse(block, id: toolId) {
                        toolsInOrder.append((id: toolId, lineIndex: lineIndex))
                        blocks.append(.toolUse(tool))
                    }
                default:
                    break
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        return ChatMessage(
            id: "cursor-\(sessionId)-\(lineIndex)",
            role: role == "user" ? .user : .assistant,
            // Synthetic but strictly increasing, so the sort in SessionStore
            // preserves file order.
            timestamp: baseDate.addingTimeInterval(Double(lineIndex) * 0.001),
            content: blocks
        )
    }

    /// Cursor wraps prompt text in `<timestamp>…</timestamp>` and `<user_query>…</user_query>`
    /// envelopes. Strip them so the notch shows the prompt, not the scaffolding.
    /// Returns nil for text that is pure scaffolding.
    static func cleanUserText(_ raw: String) -> String? {
        var text = raw

        if let query = firstTagContents(in: text, tag: "user_query") {
            text = query
        } else {
            text = removeTag(in: text, tag: "timestamp")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Contents of the first `<tag>…</tag>` pair, if present.
    private static func firstTagContents(in text: String, tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// The text with the first `<tag>…</tag>` pair removed entirely.
    private static func removeTag(in text: String, tag: String) -> String {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return text
        }
        return text.replacingCharacters(in: open.lowerBound..<close.upperBound, with: "")
    }

    private static func parseToolUse(_ block: [String: Any], id: String) -> ToolUseBlock? {
        guard let rawName = block["name"] as? String else { return nil }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                let mappedKey = Self.inputKeyMap[key] ?? key
                if let str = value as? String {
                    input[mappedKey] = str
                } else if let int = value as? Int {
                    input[mappedKey] = String(int)
                } else if let bool = value as? Bool {
                    input[mappedKey] = bool ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: Self.toolNameMap[rawName] ?? rawName, input: input)
    }

    // MARK: - Vocabulary Mapping

    /// Cursor names its tools differently from Claude. The notch's icons,
    /// previews and result renderers all switch on Claude's names, so translate
    /// the ones that have a true equivalent and let the rest fall through to
    /// generic rendering under their own name (ReadLints, SwitchMode, …).
    static let toolNameMap: [String: String] = [
        "ReadFile": "Read",
        "ApplyPatch": "Edit",
        "Shell": "Bash",
        "AwaitShell": "Bash",
        "rg": "Grep",
        "Glob": "Glob",
        "TodoWrite": "TodoWrite",
        "Subagent": "Task",
        "WebFetch": "WebFetch",
        "WebSearch": "WebSearch",
    ]

    /// Cursor's input keys for the mapped tools, translated to the keys the
    /// notch's previews read (`ToolUseBlock.preview`, `formatToolInput`).
    static let inputKeyMap: [String: String] = [
        "path": "file_path",
        "query": "query",
    ]

    // MARK: - Conversation Info (titles / list subtitles)

    /// Summary + last-message info for the session list, mirroring
    /// `ConversationParser.parse` so callers can treat both agents alike.
    func parse(sessionId: String, transcriptPath: String) -> ConversationInfo {
        let empty = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )

        guard FileManager.default.fileExists(atPath: transcriptPath),
              let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
            return empty
        }

        var firstUserMessage: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = json["role"] as? String,
                  let messageDict = json["message"] as? [String: Any] else {
                continue
            }

            var text: String?
            var toolName: String?

            if let str = messageDict["content"] as? String {
                text = Self.cleanUserText(str)
            } else if let blocks = messageDict["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let raw = block["text"] as? String, let cleaned = Self.cleanUserText(raw) {
                            text = cleaned
                        }
                    case "tool_use":
                        if let raw = block["name"] as? String {
                            toolName = Self.toolNameMap[raw] ?? raw
                        }
                    default:
                        break
                    }
                }
            }

            if role == "user", firstUserMessage == nil, let text {
                firstUserMessage = String(text.prefix(50))
            }

            // Last non-empty line wins; a trailing tool call is reported as such.
            if let toolName {
                lastMessage = text
                lastMessageRole = "tool"
                lastToolName = toolName
            } else if let text {
                lastMessage = text
                lastMessageRole = role
                lastToolName = nil
            }
        }

        return ConversationInfo(
            summary: nil,  // Cursor writes no title/summary line
            lastMessage: lastMessage.map { Self.truncate($0, maxLength: 80) },
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: nil
        )
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 3)) + "..."
    }

    /// Wall-clock anchor for synthesised timestamps: the file's creation date,
    /// falling back to its modification date, then to now.
    private static func anchorDate(path: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
            ?? Date()
    }
}
