//
//  ClaudeTokenUsageParserTests.swift
//  GhostwireTests
//
//  GW-151: Claude API-token mode. Assistant lines in
//  ~/.claude/projects/<project>/*.jsonl carry message.usage{ input_tokens,
//  cache_creation_input_tokens, cache_read_input_tokens, output_tokens }
//  + message.model + top-level timestamp/requestId.
//
//  CRITICAL: transcripts repeat assistant lines (streaming updates, resumed
//  sessions copying history) - audited 2026-06-04 on this machine: 5172 of
//  7112 message ids appeared >1x (max 16x) with identical usage. Summing
//  naively double-counts; dedupe by message.id + requestId.
//

import XCTest
@testable import Ghostwire

final class ClaudeTokenUsageParserTests: XCTestCase {

    private var tempRoot: String!

    /// Fixed "now": 2026-06-04 12:00:00 UTC
    private let now = ISO8601DateFormatter().date(from: "2026-06-04T12:00:00Z")!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "gw151-claude-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func writeTranscript(project: String = "-Users-test-proj", file: String = "session-1.jsonl", lines: [String]) throws -> String {
        let dir = "\(tempRoot!)/\(project)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(file)"
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func assistantLine(
        timestamp: String, messageId: String, requestId: String,
        model: String = "claude-opus-4-8",
        input: Int, cacheCreation: Int, cacheRead: Int, output: Int
    ) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(requestId)","uuid":"u-\#(messageId)","sessionId":"s1","message":{"id":"\#(messageId)","type":"message","role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"service_tier":"standard"}}}"#
    }

    private func makeParser() -> ClaudeTokenUsageParser {
        ClaudeTokenUsageParser(projectsRoot: tempRoot)
    }

    // MARK: - Aggregation

    func testSumsUsageAcrossAssistantMessages() throws {
        try writeTranscript(lines: [
            assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                          input: 100, cacheCreation: 20, cacheRead: 1_000, output: 50),
            assistantLine(timestamp: "2026-06-04T11:05:00.000Z", messageId: "msg_2", requestId: "req_2",
                          input: 200, cacheCreation: 30, cacheRead: 2_000, output: 80)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 300)
        XCTAssertEqual(snapshot.sevenDay.cacheCreationInputTokens, 50)
        XCTAssertEqual(snapshot.sevenDay.cachedInputTokens, 3_000)
        XCTAssertEqual(snapshot.sevenDay.outputTokens, 130)
    }

    func testDuplicateMessageIdsCountOnce() throws {
        // Same message id + requestId repeated (streaming/resume duplication)
        let dup = assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                                input: 100, cacheCreation: 0, cacheRead: 0, output: 50)
        try writeTranscript(lines: [dup, dup, dup])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 100)
        XCTAssertEqual(snapshot.sevenDay.outputTokens, 50)
    }

    func testDuplicatesAcrossFilesCountOnce() throws {
        // Resumed sessions copy history into a NEW file - dedupe must be global
        let dup = assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                                input: 100, cacheCreation: 0, cacheRead: 0, output: 50)
        try writeTranscript(file: "session-1.jsonl", lines: [dup])
        try writeTranscript(file: "session-2-resumed.jsonl", lines: [dup])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 100)
    }

    // MARK: - Windows

    func testFiveHourWindowIsSubsetOfSevenDay() throws {
        try writeTranscript(lines: [
            // 2h ago → in both windows
            assistantLine(timestamp: "2026-06-04T10:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                          input: 100, cacheCreation: 0, cacheRead: 0, output: 10),
            // 2 days ago → 7D only
            assistantLine(timestamp: "2026-06-02T10:00:00.000Z", messageId: "msg_2", requestId: "req_2",
                          input: 1_000, cacheCreation: 0, cacheRead: 0, output: 100)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.fiveHour.inputTokens, 100)
        XCTAssertEqual(snapshot.sevenDay.inputTokens, 1_100)
    }

    func testEventsOlderThanSevenDaysExcluded() throws {
        try writeTranscript(lines: [
            assistantLine(timestamp: "2026-05-20T10:00:00.000Z", messageId: "msg_old", requestId: "req_old",
                          input: 9_999, cacheCreation: 0, cacheRead: 0, output: 999),
            assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_new", requestId: "req_new",
                          input: 100, cacheCreation: 0, cacheRead: 0, output: 10)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 100)
    }

    func testFilesWithOldMtimeAreSkipped() throws {
        // The mtime filter avoids opening untouched transcripts. A file whose
        // mtime predates the 7-day window can't contain in-window events.
        let path = try writeTranscript(file: "stale.jsonl", lines: [
            assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                          input: 5_000, cacheCreation: 0, cacheRead: 0, output: 500)
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: path
        )

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay, .zero)
        XCTAssertFalse(snapshot.hasData)
    }

    // MARK: - Model attribution & robustness

    func testTokensAttributedToModel() throws {
        try writeTranscript(lines: [
            assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                          model: "claude-opus-4-8", input: 100, cacheCreation: 0, cacheRead: 0, output: 10),
            assistantLine(timestamp: "2026-06-04T11:01:00.000Z", messageId: "msg_2", requestId: "req_2",
                          model: "claude-haiku-4-5-20251001", input: 200, cacheCreation: 0, cacheRead: 0, output: 20)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.tokensByModel["claude-opus-4-8"]?.inputTokens, 100)
        XCTAssertEqual(snapshot.tokensByModel["claude-haiku-4-5-20251001"]?.inputTokens, 200)
    }

    func testSyntheticModelLinesSkipped() throws {
        // "<synthetic>" assistant lines are local error placeholders, not
        // billed API calls (present in real transcripts on this machine)
        try writeTranscript(lines: [
            assistantLine(timestamp: "2026-06-04T11:00:00.000Z", messageId: "msg_1", requestId: "req_1",
                          model: "<synthetic>", input: 999, cacheCreation: 0, cacheRead: 0, output: 99),
            assistantLine(timestamp: "2026-06-04T11:01:00.000Z", messageId: "msg_2", requestId: "req_2",
                          input: 100, cacheCreation: 0, cacheRead: 0, output: 10)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 100)
    }

    func testNonAssistantAndMalformedLinesSkipped() throws {
        try writeTranscript(lines: [
            #"{"type":"last-prompt","leafUuid":"x","sessionId":"s1"}"#,
            #"{"type":"user","timestamp":"2026-06-04T10:59:00.000Z","message":{"role":"user","content":"hi"}}"#,
            "garbage {{{ not json",
            #"{"type":"assistant","timestamp":"2026-06-04T11:00:00.000Z","message":{"id":"msg_nousage","model":"claude-opus-4-8"}}"#,
            assistantLine(timestamp: "2026-06-04T11:01:00.000Z", messageId: "msg_1", requestId: "req_1",
                          input: 100, cacheCreation: 0, cacheRead: 0, output: 10)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.sevenDay.inputTokens, 100)
        XCTAssertEqual(snapshot.sevenDay.outputTokens, 10)
    }

    func testEmptyRootYieldsEmptySnapshot() {
        let snapshot = makeParser().snapshot(now: now)
        XCTAssertFalse(snapshot.hasData)
    }
}
