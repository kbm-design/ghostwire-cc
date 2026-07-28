//
//  CursorTranscriptParserTests.swift
//  GhostwireTests
//
//  GW-311: Cursor's agent-transcript JSONL is Claude-shaped at the content-block
//  level but leaner in the envelope. Fixtures below mirror the live format
//  verified against ~/.cursor/projects/*/agent-transcripts (2026-07-23): every
//  line is {"role", "message"} only — no `type`, `uuid`, `timestamp`, no `id` on
//  tool_use blocks, and no tool_result blocks anywhere.
//

import XCTest
@testable import Ghostwire

final class CursorTranscriptParserTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gw311-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func write(_ lines: [String], to name: String = "t.jsonl") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func append(_ lines: [String], to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.joined(separator: "\n").appending("\n").utf8))
    }

    // The exact envelope Cursor writes: role + message only.
    private let userLine = """
    {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Monday, Apr 27, 2026, 3:35 AM (UTC-7)</timestamp>\\n<user_query>\\nfix the header spacing\\n</user_query>"}]}}
    """
    private let assistantTextLine = """
    {"role":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}
    """
    private let readToolLine = """
    {"role":"assistant","message":{"content":[{"type":"tool_use","name":"ReadFile","input":{"path":"/tmp/App.tsx"}}]}}
    """
    private let shellToolLine = """
    {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"npm run build"}}]}}
    """

    // MARK: - Envelope

    func testParsesLeanEnvelopeIntoMessages() async throws {
        let path = try write([userLine, assistantTextLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s1", transcriptPath: path)

        XCTAssertEqual(result.newMessages.count, 2)
        XCTAssertEqual(result.newMessages[0].role, .user)
        XCTAssertEqual(result.newMessages[1].role, .assistant)
    }

    /// The prompt must arrive without Cursor's <timestamp>/<user_query> scaffolding.
    func testStripsUserQueryScaffolding() async throws {
        let path = try write([userLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s2", transcriptPath: path)

        let text = try XCTUnwrap(result.newMessages.first?.textContent)
        XCTAssertEqual(text, "fix the header spacing")
        XCTAssertFalse(text.contains("<user_query>"))
        XCTAssertFalse(text.contains("<timestamp>"))
    }

    // MARK: - Tool vocabulary

    func testMapsCursorToolNamesAndInputKeysToClaudeEquivalents() async throws {
        let path = try write([readToolLine, shellToolLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s3", transcriptPath: path)

        let tools = result.newMessages.flatMap { $0.content }.compactMap { block -> ToolUseBlock? in
            if case .toolUse(let t) = block { return t }
            return nil
        }
        XCTAssertEqual(tools.map(\.name), ["Read", "Bash"])
        // `path` is remapped so the existing preview/renderers find it.
        XCTAssertEqual(tools[0].input["file_path"], "/tmp/App.tsx")
        XCTAssertEqual(tools[1].input["command"], "npm run build")
    }

    /// Cursor-only tools have no Claude equivalent and must survive under their
    /// own name rather than being dropped.
    func testUnmappedToolKeepsItsCursorName() async throws {
        let line = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"ReadLints","input":{"paths":"src"}}]}}
        """
        let path = try write([line])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s4", transcriptPath: path)

        guard case .toolUse(let tool)? = result.newMessages.first?.content.first else {
            return XCTFail("expected a tool block")
        }
        XCTAssertEqual(tool.name, "ReadLints")
    }

    /// Cursor omits tool ids; synthesised ones must be unique per call so chat
    /// items don't collapse into one another.
    func testSynthesisedToolIdsAreUnique() async throws {
        let path = try write([readToolLine, readToolLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s5", transcriptPath: path)

        let ids = result.newMessages.flatMap { $0.content }.compactMap { block -> String? in
            if case .toolUse(let t) = block { return t.id }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "identical calls must still get distinct ids")
    }

    // MARK: - Inferred completion

    /// No tool_result exists in the format, so completion is positional: a tool
    /// with any later line has demonstrably returned; the trailing one has not.
    func testAllToolsButTheLastAreInferredComplete() async throws {
        let path = try write([readToolLine, shellToolLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s6", transcriptPath: path)

        let ids = result.newMessages.flatMap { $0.content }.compactMap { block -> String? in
            if case .toolUse(let t) = block { return t.id }
            return nil
        }
        XCTAssertEqual(result.completedToolIds, [ids[0]])
        XCTAssertFalse(result.completedToolIds.contains(ids[1]), "trailing tool stays running")
    }

    /// The trailing tool from an earlier sync must settle once later lines land —
    /// the store's append path never revisits an existing item's status.
    func testTrailingToolSettlesOnNextParse() async throws {
        let path = try write([readToolLine])
        let first = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s7", transcriptPath: path)
        XCTAssertTrue(first.completedToolIds.isEmpty)
        XCTAssertTrue(first.newlyCompletedToolIds.isEmpty)

        try append([assistantTextLine], to: path)
        let second = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s7", transcriptPath: path)

        XCTAssertEqual(second.newlyCompletedToolIds.count, 1, "the once-trailing tool now reports complete")
    }

    /// Each completion is reported once, so repeated syncs don't re-emit events.
    func testCompletionIsReportedOnlyOnce() async throws {
        let path = try write([readToolLine, assistantTextLine])
        _ = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s8", transcriptPath: path)

        try append([assistantTextLine], to: path)
        let second = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s8", transcriptPath: path)

        XCTAssertTrue(second.newlyCompletedToolIds.isEmpty)
    }

    // MARK: - Incremental reads

    func testIncrementalParseReturnsOnlyAppendedLines() async throws {
        let path = try write([userLine])
        let first = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s9", transcriptPath: path)
        XCTAssertEqual(first.newMessages.count, 1)

        try append([assistantTextLine], to: path)
        let second = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s9", transcriptPath: path)

        XCTAssertEqual(second.newMessages.count, 1, "only the appended line is new")
        XCTAssertEqual(second.allMessages.count, 2)
    }

    /// Message ids key off the line index, so a re-read of the same line yields
    /// the same id — that is what lets the store's append path dedup.
    func testMessageIdsAreStableAcrossReparses() async throws {
        let path = try write([userLine, assistantTextLine])
        let first = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s10", transcriptPath: path)

        await CursorTranscriptParser.shared.resetState(for: "s10")
        let second = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s10", transcriptPath: path)

        XCTAssertEqual(first.newMessages.map(\.id), second.newMessages.map(\.id))
    }

    /// Synthetic timestamps must strictly increase: SessionStore sorts chat items
    /// by timestamp, so equal values would let file order scramble.
    func testTimestampsIncreaseInFileOrder() async throws {
        let path = try write([userLine, assistantTextLine, readToolLine])
        let result = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s11", transcriptPath: path)

        let stamps = result.newMessages.map(\.timestamp)
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count, "timestamps must be distinct")
    }

    /// A truncated/replaced file (new conversation reusing the id) must reset
    /// rather than read from a stale offset.
    func testTruncationResetsState() async throws {
        let path = try write([userLine, assistantTextLine, readToolLine])
        _ = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s12", transcriptPath: path)

        try write([assistantTextLine], to: "t.jsonl")
        let after = await CursorTranscriptParser.shared.parseIncremental(sessionId: "s12", transcriptPath: path)

        XCTAssertEqual(after.allMessages.count, 1, "state restarts from the new, shorter file")
    }

    func testMissingFileIsHandledGracefully() async throws {
        let result = await CursorTranscriptParser.shared.parseIncremental(
            sessionId: "s13",
            transcriptPath: tempDir.appendingPathComponent("nope.jsonl").path
        )
        XCTAssertTrue(result.newMessages.isEmpty)
    }

    // MARK: - Conversation info (titles)

    /// Cursor writes no summary/ai-title line, so the session title has to come
    /// from the first prompt — with the scaffolding stripped (the "/" title fix).
    func testConversationInfoTitlesFromFirstPrompt() async throws {
        let path = try write([userLine, assistantTextLine])
        let info = await CursorTranscriptParser.shared.parse(sessionId: "s14", transcriptPath: path)

        XCTAssertEqual(info.firstUserMessage, "fix the header spacing")
        XCTAssertNil(info.summary)
        XCTAssertEqual(info.lastMessage, "On it.")
        XCTAssertEqual(info.lastMessageRole, "assistant")
    }

    func testConversationInfoReportsTrailingToolWithMappedName() async throws {
        let path = try write([userLine, readToolLine])
        let info = await CursorTranscriptParser.shared.parse(sessionId: "s15", transcriptPath: path)

        XCTAssertEqual(info.lastMessageRole, "tool")
        XCTAssertEqual(info.lastToolName, "Read")
    }

    // MARK: - Session naming

    /// Payloads with no cwd (Cursor's beforeSubmitPrompt/stop) used to title the
    /// session "/" — the last path component of an empty path.
    func testEmptyCwdDoesNotProduceSlashTitle() {
        let session = SessionState(sessionId: "s16", cwd: "")

        XCTAssertNotEqual(session.projectName, "/")
        XCTAssertNotEqual(session.displayTitle, "/")
    }

    func testRootCwdDoesNotProduceSlashTitle() {
        let session = SessionState(sessionId: "s17", cwd: "/")

        XCTAssertNotEqual(session.displayTitle, "/")
    }

    func testRealCwdStillNamesTheProject() {
        let session = SessionState(sessionId: "s18", cwd: "/Users/x/Desktop/Coding/Notch")

        XCTAssertEqual(session.projectName, "Notch")
    }
}
