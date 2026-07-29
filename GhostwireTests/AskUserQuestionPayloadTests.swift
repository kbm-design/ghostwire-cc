//
//  AskUserQuestionPayloadTests.swift
//  GhostwireTests
//
//  GW-321 (State B). Fixtures are real payloads captured from live Claude Code
//  2.1.220 during the GW-318 spike — not invented shapes.
//  See docs/interaction-model-payloads.md.
//

import XCTest
@testable import Ghostwire

final class AskUserQuestionPayloadTests: XCTestCase {

    /// Verbatim `tool_input` from a live PreToolUse/PermissionRequest capture.
    private func singleSelectPayload() -> [String: AnyCodable] {
        [
            "questions": AnyCodable([
                [
                    "question": "Do you prefer tabs or spaces for indentation?",
                    "header": "Indentation",
                    "multiSelect": false,
                    "options": [
                        [
                            "label": "Tabs",
                            "description": "Indent with tab characters — width is set by each reader's editor."
                        ],
                        [
                            "label": "Spaces",
                            "description": "Indent with space characters — identical width everywhere."
                        ]
                    ]
                ]
            ])
        ]
    }

    /// Real multi-select capture (`multiSelect: true`, 4 options).
    private func multiSelectPayload() -> [String: AnyCodable] {
        [
            "questions": AnyCodable([
                [
                    "question": "Which languages do you use?",
                    "header": "Languages",
                    "multiSelect": true,
                    "options": [
                        ["label": "Swift", "description": "Apple platforms."],
                        ["label": "Python", "description": "Scripting, data work."],
                        ["label": "Rust", "description": "Systems programming."],
                        ["label": "Go", "description": "Backend services."]
                    ]
                ]
            ])
        ]
    }

    // MARK: - Parsing

    func testParsesSingleSelectQuestion() {
        let request = AskUserQuestionRequest(toolInput: singleSelectPayload())
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.questions.count, 1)

        let question = request!.questions[0]
        XCTAssertEqual(question.question, "Do you prefer tabs or spaces for indentation?")
        XCTAssertEqual(question.header, "Indentation")
        XCTAssertFalse(question.multiSelect)
        XCTAssertEqual(question.options.map(\.label), ["Tabs", "Spaces"])
        XCTAssertEqual(question.options[0].description,
                       "Indent with tab characters — width is set by each reader's editor.")
    }

    func testParsesMultiSelectFlag() {
        let request = AskUserQuestionRequest(toolInput: multiSelectPayload())
        XCTAssertEqual(request?.questions.first?.multiSelect, true)
        XCTAssertEqual(request?.questions.first?.options.count, 4)
    }

    func testParsesMultiQuestionCall() {
        // 33 of 96 sampled calls carried more than one question — the renderer
        // must not assume a single question.
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["question": "Q1", "header": "A",
                 "options": [["label": "L1", "description": "d"]]],
                ["question": "Q2", "header": "B", "multiSelect": true,
                 "options": [["label": "L2", "description": "d"]]]
            ])
        ]
        let request = AskUserQuestionRequest(toolInput: payload)
        XCTAssertEqual(request?.questions.count, 2)
        XCTAssertEqual(request?.questions[1].multiSelect, true)
    }

    func testParsesOptionalPreviewField() {
        // Newer field, present on 70/424 sampled options.
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["question": "Pick a layout",
                 "options": [["label": "Grid", "description": "d", "preview": "┌──┬──┐"]]]
            ])
        ]
        let request = AskUserQuestionRequest(toolInput: payload)
        XCTAssertEqual(request?.questions.first?.options.first?.preview, "┌──┬──┐")
    }

    func testDecodesCodexPerQuestionId() {
        // Codex's request_user_input adds a stable `id` — a better correlation
        // key than question text, which is all Claude gives us.
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["id": "next_bias", "question": "What next?", "header": "Next",
                 "options": [["label": "Home first", "description": "d"]]]
            ])
        ]
        let request = AskUserQuestionRequest(toolInput: payload)
        XCTAssertEqual(request?.questions.first?.id, "next_bias")
        XCTAssertEqual(request?.questions.first?.key, "next_bias",
                       "id wins over question text as the correlation key")
    }

    func testMultiQuestionClaudePayloadHasDistinctIdentities() {
        // Regression: `Identifiable` used the stored optional `id`, which Claude
        // never sends. Both questions therefore had identity nil, and ForEach
        // rendered one question twice with selections moving in lockstep. Caught
        // live, not here — these tests never rendered — so assert the invariant
        // the view depends on.
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["question": "Which state next?",
                 "options": [["label": "State C", "description": "d"]]],
                ["question": "Which rough edges?", "multiSelect": true,
                 "options": [["label": "Scrolling", "description": "d"]]]
            ])
        ]
        let request = AskUserQuestionRequest(toolInput: payload)
        XCTAssertEqual(request?.questions.count, 2)

        let ids = request!.questions.map(\.id)
        XCTAssertEqual(Set(ids).count, 2, "each question needs its own ForEach identity")
        XCTAssertEqual(ids, ["Which state next?", "Which rough edges?"])

        // Answers are keyed by the same value, so they must not collide either.
        let keys = request!.questions.map(\.key)
        XCTAssertEqual(Set(keys).count, 2)
    }

    func testKeyFallsBackToQuestionTextWhenNoId() {
        let request = AskUserQuestionRequest(toolInput: singleSelectPayload())
        XCTAssertEqual(request?.questions.first?.key,
                       "Do you prefer tabs or spaces for indentation?")
    }

    // MARK: - Refusing to render a partial question

    func testRejectsNonQuestionPayload() {
        // A Bash gate must never render as a Choice.
        XCTAssertNil(AskUserQuestionRequest(toolInput: ["command": AnyCodable("ls -la")]))
    }

    func testRejectsPayloadWithAMalformedQuestion() {
        // One bad question invalidates the whole render: silently dropping it
        // would let the user answer a set they never fully saw.
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["question": "Good", "options": [["label": "L", "description": "d"]]],
                ["header": "no question text here", "options": [["label": "L"]]]
            ])
        ]
        XCTAssertNil(AskUserQuestionRequest(toolInput: payload))
    }

    func testRejectsQuestionWithNoOptions() {
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([["question": "Q", "options": []]])
        ]
        XCTAssertNil(AskUserQuestionRequest(toolInput: payload))
    }

    // MARK: - Reply formatting

    func testReplyMessageMirrorsClaudesOwnWording() {
        let request = AskUserQuestionRequest(toolInput: singleSelectPayload())!
        let message = request.replyMessage(
            answers: ["Do you prefer tabs or spaces for indentation?": "Spaces"]
        )
        XCTAssertEqual(
            message,
            "Your questions have been answered: "
            + "\"Do you prefer tabs or spaces for indentation?\"=\"Spaces\". "
            + "You can now continue with these answers in mind."
        )
    }

    func testReplyMessageCarriesFreeText() {
        // Real answers are frequently not any option label — the terminal always
        // offers a "Type something" row, so the notch must pass text through.
        let request = AskUserQuestionRequest(toolInput: singleSelectPayload())!
        let message = request.replyMessage(
            answers: ["Do you prefer tabs or spaces for indentation?": "tabs at work, spaces here"]
        )
        XCTAssertTrue(message.contains("\"tabs at work, spaces here\""))
    }

    func testReplyMessageIncludesEveryAnsweredQuestion() {
        let payload: [String: AnyCodable] = [
            "questions": AnyCodable([
                ["question": "Q1", "options": [["label": "A", "description": "d"]]],
                ["question": "Q2", "options": [["label": "B", "description": "d"]]]
            ])
        ]
        let request = AskUserQuestionRequest(toolInput: payload)!
        let message = request.replyMessage(answers: ["Q1": "A", "Q2": "B"])
        XCTAssertTrue(message.contains("\"Q1\"=\"A\""))
        XCTAssertTrue(message.contains("\"Q2\"=\"B\""))
    }

    func testReplyMessageWithNoAnswersIsExplicit() {
        let request = AskUserQuestionRequest(toolInput: singleSelectPayload())!
        XCTAssertEqual(request.replyMessage(answers: [:]),
                       "The user dismissed the question without answering.")
    }

    // MARK: - Codable (spec §8: gateway / phone readiness)

    func testRoundTripsThroughJSON() {
        let request = AskUserQuestionRequest(toolInput: multiSelectPayload())!
        let data = try! JSONEncoder().encode(request)
        let decoded = try! JSONDecoder().decode(AskUserQuestionRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }
}
