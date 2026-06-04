//
//  CodexUsageParserTests.swift
//  GhostwireTests
//
//  GW-151: per-agent usage meter. Codex usage comes from token_count
//  event_msg lines in ~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl:
//    payload.info.total_token_usage / last_token_usage
//      = { input_tokens, cached_input_tokens, output_tokens,
//          reasoning_output_tokens, total_tokens }
//    payload.info.model_context_window
//    payload.rate_limits = { primary:  { used_percent, window_minutes ~299,
//                                        resets_in_seconds },
//                            secondary { ...window_minutes ~10079... } }
//  rate_limits is non-null ONLY under ChatGPT-subscription auth; null under
//  API-key auth. The meter mode branches on that (latest event wins).
//  Fixture shapes sanitized from real rollouts on this machine (codex 0.136.0
//  apikey session + a 2025 subscription session).
//

import XCTest
@testable import Ghostwire

final class CodexUsageParserTests: XCTestCase {

    private var tempRoot: String!

    /// Fixed "now" so 5H/7D window math is deterministic: 2026-06-04 12:00:00 UTC
    private let now = ISO8601DateFormatter().date(from: "2026-06-04T12:00:00Z")!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "gw151-codex-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    // MARK: - Fixture helpers

    /// Write a rollout file under the date-sharded tree (Y/M/D taken from `day`).
    @discardableResult
    private func writeRollout(day: String, sessionId: String, lines: [String]) throws -> String {
        let parts = day.split(separator: "-")
        let dir = "\(tempRoot!)/\(parts[0])/\(parts[1])/\(parts[2])"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/rollout-\(day)T08-00-00-\(sessionId).jsonl"
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func sessionMeta(timestamp: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"x","timestamp":"\#(timestamp)","cwd":"/tmp","cli_version":"0.136.0"}}"#
    }

    private func turnContext(timestamp: String, model: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"t","model":"\#(model)","effort":"high"}}"#
    }

    private func tokenCount(
        timestamp: String,
        input: Int, cached: Int, output: Int, reasoning: Int,
        contextWindow: Int = 258_400,
        rateLimits: String = "null"
    ) -> String {
        let total = input + output
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110},"model_context_window":\#(contextWindow)},"rate_limits":\#(rateLimits)}}"#
    }

    private func subscriptionRateLimits(
        fiveHourPercent: Double, fiveHourResets: Int,
        sevenDayPercent: Double, sevenDayResets: Int
    ) -> String {
        #"{"primary":{"used_percent":\#(fiveHourPercent),"window_minutes":299,"resets_in_seconds":\#(fiveHourResets)},"secondary":{"used_percent":\#(sevenDayPercent),"window_minutes":10079,"resets_in_seconds":\#(sevenDayResets)}}"#
    }

    private func makeParser() -> CodexUsageParser {
        CodexUsageParser(sessionsRoot: tempRoot)
    }

    // MARK: - API-key auth (rate_limits null) → token mode

    func testApiKeySessionYieldsTokenModeWithSummedTotals() throws {
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            sessionMeta(timestamp: "2026-06-04T08:00:00.000Z"),
            turnContext(timestamp: "2026-06-04T08:00:01.000Z", model: "gpt-5.5"),
            // Cumulative totals grow per event; only the LATEST per session counts
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 800, output: 50, reasoning: 10),
            tokenCount(timestamp: "2026-06-04T09:00:00.000Z", input: 5_000, cached: 4_000, output: 200, reasoning: 40)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertNil(snapshot.rateLimits, "apikey sessions log rate_limits: null")
        XCTAssertEqual(snapshot.tokens.inputTokens, 5_000)
        XCTAssertEqual(snapshot.tokens.cachedInputTokens, 4_000)
        XCTAssertEqual(snapshot.tokens.outputTokens, 200)
        XCTAssertEqual(snapshot.tokens.reasoningOutputTokens, 40)
    }

    func testTotalsSumAcrossSessionsButNotWithinASession() throws {
        // total_token_usage is cumulative WITHIN a session - summing every
        // event would double-count. Across sessions they're independent.
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            turnContext(timestamp: "2026-06-04T08:00:01.000Z", model: "gpt-5.5"),
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 0, output: 100, reasoning: 0),
            tokenCount(timestamp: "2026-06-04T08:02:00.000Z", input: 2_000, cached: 0, output: 200, reasoning: 0)
        ])
        try writeRollout(day: "2026-06-03", sessionId: "bbbbbbbb-0000-0000-0000-000000000002", lines: [
            turnContext(timestamp: "2026-06-03T10:00:01.000Z", model: "gpt-5.5"),
            tokenCount(timestamp: "2026-06-03T10:01:00.000Z", input: 3_000, cached: 0, output: 300, reasoning: 0)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.tokens.inputTokens, 5_000)   // 2000 + 3000, NOT 1000+2000+3000
        XCTAssertEqual(snapshot.tokens.outputTokens, 500)    // 200 + 300
    }

    func testTokensAttributedToModelFromTurnContext() throws {
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            turnContext(timestamp: "2026-06-04T08:00:01.000Z", model: "gpt-5.5"),
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 0, output: 100, reasoning: 0)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.tokensByModel["gpt-5.5"]?.inputTokens, 1_000)
    }

    // MARK: - Subscription auth (rate_limits present) → quota mode

    func testSubscriptionSessionYieldsQuotaModeWithResetDates() throws {
        try writeRollout(day: "2026-06-04", sessionId: "cccccccc-0000-0000-0000-000000000003", lines: [
            turnContext(timestamp: "2026-06-04T10:00:01.000Z", model: "gpt-5.5"),
            tokenCount(
                timestamp: "2026-06-04T10:01:00.000Z",
                input: 48_773, cached: 45_056, output: 165, reasoning: 64,
                rateLimits: subscriptionRateLimits(
                    fiveHourPercent: 10.0, fiveHourResets: 8_551,
                    sevenDayPercent: 3.0, sevenDayResets: 595_351
                )
            )
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.rateLimits?.fiveHour?.utilization, 10.0)
        XCTAssertEqual(snapshot.rateLimits?.sevenDay?.utilization, 3.0)

        // resetsAt anchors to the EVENT timestamp (10:01:00Z), not `now`
        let eventDate = ISO8601DateFormatter.gw151.date(from: "2026-06-04T10:01:00.000Z")!
        XCTAssertEqual(
            snapshot.rateLimits?.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0,
            eventDate.addingTimeInterval(8_551).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            snapshot.rateLimits?.sevenDay?.resetsAt?.timeIntervalSince1970 ?? 0,
            eventDate.addingTimeInterval(595_351).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testLatestEventAcrossSessionsDecidesMode() throws {
        // Auth flip mid-window: older subscription session, newer apikey
        // session → latest token_count wins → token mode (rateLimits nil).
        try writeRollout(day: "2026-06-03", sessionId: "cccccccc-0000-0000-0000-000000000003", lines: [
            tokenCount(
                timestamp: "2026-06-03T08:00:00.000Z",
                input: 100, cached: 0, output: 10, reasoning: 0,
                rateLimits: subscriptionRateLimits(
                    fiveHourPercent: 50.0, fiveHourResets: 1000,
                    sevenDayPercent: 20.0, sevenDayResets: 2000
                )
            )
        ])
        try writeRollout(day: "2026-06-04", sessionId: "dddddddd-0000-0000-0000-000000000004", lines: [
            tokenCount(timestamp: "2026-06-04T11:00:00.000Z", input: 200, cached: 0, output: 20, reasoning: 0)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertNil(snapshot.rateLimits, "latest token_count has rate_limits null → token mode")
    }

    func testFlipBackToSubscriptionAlsoWins() throws {
        try writeRollout(day: "2026-06-03", sessionId: "dddddddd-0000-0000-0000-000000000004", lines: [
            tokenCount(timestamp: "2026-06-03T08:00:00.000Z", input: 200, cached: 0, output: 20, reasoning: 0)
        ])
        try writeRollout(day: "2026-06-04", sessionId: "cccccccc-0000-0000-0000-000000000003", lines: [
            tokenCount(
                timestamp: "2026-06-04T11:00:00.000Z",
                input: 100, cached: 0, output: 10, reasoning: 0,
                rateLimits: subscriptionRateLimits(
                    fiveHourPercent: 36.0, fiveHourResets: 3_000,
                    sevenDayPercent: 8.0, sevenDayResets: 200_000
                )
            )
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.rateLimits?.fiveHour?.utilization, 36.0)
    }

    // MARK: - Context window

    func testContextGaugeComesFromLatestEvent() throws {
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 0, output: 100, reasoning: 0, contextWindow: 258_400)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.modelContextWindow, 258_400)
        XCTAssertEqual(snapshot.lastContextUsed, 110)  // last_token_usage.total
    }

    // MARK: - Window filtering & robustness

    func testSessionsOlderThanSevenDaysAreExcluded() throws {
        try writeRollout(day: "2026-05-20", sessionId: "eeeeeeee-0000-0000-0000-000000000005", lines: [
            tokenCount(timestamp: "2026-05-20T08:00:00.000Z", input: 9_999, cached: 0, output: 999, reasoning: 0)
        ])
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 0, output: 100, reasoning: 0)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.tokens.inputTokens, 1_000, "2026-05-20 is outside the 7-day window")
    }

    func testNoTokenCountEventsYieldsEmptySnapshot() throws {
        try writeRollout(day: "2026-06-04", sessionId: "ffffffff-0000-0000-0000-000000000006", lines: [
            sessionMeta(timestamp: "2026-06-04T08:00:00.000Z"),
            turnContext(timestamp: "2026-06-04T08:00:01.000Z", model: "gpt-5.5")
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertNil(snapshot.rateLimits)
        XCTAssertEqual(snapshot.tokens, .zero)
        XCTAssertFalse(snapshot.hasData)
    }

    func testEmptyRootYieldsEmptySnapshot() {
        let snapshot = makeParser().snapshot(now: now)
        XCTAssertFalse(snapshot.hasData)
        XCTAssertEqual(snapshot.tokens, .zero)
    }

    func testMalformedLinesAreSkipped() throws {
        try writeRollout(day: "2026-06-04", sessionId: "aaaaaaaa-0000-0000-0000-000000000001", lines: [
            "not json at all {{{",
            #"{"timestamp":"2026-06-04T08:00:30.000Z","type":"event_msg","payload":{"type":"token_count"}}"#,  // no info
            tokenCount(timestamp: "2026-06-04T08:01:00.000Z", input: 1_000, cached: 0, output: 100, reasoning: 0)
        ])

        let snapshot = makeParser().snapshot(now: now)

        XCTAssertEqual(snapshot.tokens.inputTokens, 1_000)
    }
}

private extension ISO8601DateFormatter {
    static let gw151: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
