//
//  CodexTranscriptParserTests.swift
//  GhostwireTests
//
//  GW-191: Codex transcript parsing — title / preview / history for Codex
//  sessions. Rollout files live at ~/.codex/sessions/<Y>/<M>/<D>/
//  rollout-<ts>-<uuid>.jsonl with a different schema from Claude's JSONL:
//  session_meta / event_msg (user_message, agent_message) / response_item
//  (message, function_call, function_call_output, reasoning).
//
//  Fixture below is sanitized from a real rollout (codex-tui 0.135.0).
//

import XCTest
@testable import Ghostwire

final class CodexTranscriptParserTests: XCTestCase {

    private let sessionId = "019e8bd5-369f-7681-8840-4830234ab673"
    private var tempRoot: String!
    private var parser: CodexTranscriptParser!

    override func setUpWithError() throws {
        tempRoot = NSTemporaryDirectory() + "gw191-tests-" + UUID().uuidString
        let dayDir = tempRoot + "/2026/06/02"
        try FileManager.default.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
        let file = dayDir + "/rollout-2026-06-02T21-54-26-\(sessionId).jsonl"
        try Self.fixture.write(toFile: file, atomically: true, encoding: .utf8)
        parser = CodexTranscriptParser(sessionsRoot: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    // MARK: - Path resolution

    func testResolvesRolloutFileBySessionUUID() async {
        let path = await parser.rolloutFilePath(sessionId: sessionId)
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasSuffix("-\(sessionId).jsonl") == true)
    }

    func testUnknownSessionResolvesNil() async {
        let path = await parser.rolloutFilePath(sessionId: "00000000-dead-beef-0000-000000000000")
        XCTAssertNil(path)
    }

    // MARK: - ConversationInfo (title / preview)

    func testFirstUserMessageComesFromEventMsgNotInjectedInstructions() async {
        // response_item user messages carry AGENTS.md instruction injection;
        // event_msg user_message is the clean "what the user typed" signal.
        let info = await parser.parse(sessionId: sessionId)
        XCTAssertEqual(info.firstUserMessage, "Run the shell command: echo hello > out.txt")
    }

    func testLastMessageIsLatestAgentMessage() async {
        let info = await parser.parse(sessionId: sessionId)
        XCTAssertEqual(info.lastMessageRole, "assistant")
        XCTAssertEqual(info.lastMessage?.contains("blocked by the environment"), true)
    }

    func testLastUserMessageDateParsed() async {
        let info = await parser.parse(sessionId: sessionId)
        XCTAssertNotNil(info.lastUserMessageDate)
    }

    func testMissingFileReturnsEmptyInfo() async {
        let info = await parser.parse(sessionId: "00000000-dead-beef-0000-000000000000")
        XCTAssertNil(info.firstUserMessage)
        XCTAssertNil(info.lastMessage)
    }

    // MARK: - Conversation history

    func testHistoryContainsUserAndAssistantMessages() async {
        let conversation = await parser.parseConversation(sessionId: sessionId)
        let userTexts = conversation.messages.filter { $0.role == .user }
        let assistantTexts = conversation.messages.filter { $0.role == .assistant && !$0.textContent.isEmpty }

        XCTAssertEqual(userTexts.count, 2)
        XCTAssertEqual(userTexts.first?.textContent, "Run the shell command: echo hello > out.txt")
        XCTAssertGreaterThanOrEqual(assistantTexts.count, 2)
    }

    func testHistoryContainsToolCallsWithCallIds() async {
        let conversation = await parser.parseConversation(sessionId: sessionId)

        var toolBlocks: [ToolUseBlock] = []
        for message in conversation.messages {
            for block in message.content {
                if case .toolUse(let tool) = block { toolBlocks.append(tool) }
            }
        }

        XCTAssertEqual(toolBlocks.count, 2)
        XCTAssertEqual(toolBlocks.first?.id, "call_arMntF5ySYVCEfdtVSitV2Eg")
        XCTAssertEqual(toolBlocks.first?.name, "exec_command")
        // Codex "cmd" argument is surfaced as "command" so ToolUseBlock.preview works
        XCTAssertEqual(toolBlocks.first?.input["command"], "echo hello > out.txt")
    }

    func testCompletedToolIdsAndResults() async {
        let conversation = await parser.parseConversation(sessionId: sessionId)

        XCTAssertTrue(conversation.completedToolIds.contains("call_arMntF5ySYVCEfdtVSitV2Eg"))
        XCTAssertTrue(conversation.completedToolIds.contains("call_MZL6mhXERQznpfRKptETIdKo"))
        XCTAssertEqual(
            conversation.toolResults["call_MZL6mhXERQznpfRKptETIdKo"]?.content?.contains("Denied by user via Ghostwire"),
            true
        )
    }

    func testMessagesHaveStableIds() async {
        let first = await parser.parseConversation(sessionId: sessionId)
        let second = await parser.parseConversation(sessionId: sessionId)
        XCTAssertEqual(first.messages.map { $0.id }, second.messages.map { $0.id })
    }

    // MARK: - Fixture (sanitized real rollout, codex-tui 0.135.0)

    private static let fixture = """
{"timestamp":"2026-06-03T04:54:38.840Z","type":"session_meta","payload":{"id":"019e8bd5-369f-7681-8840-4830234ab673","timestamp":"2026-06-03T04:54:26.719Z","cwd":"/private/tmp/gw168-test","originator":"codex-tui","cli_version":"0.135.0","source":"cli"}}
{"timestamp":"2026-06-03T04:54:38.841Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"# developer instructions"}]}}
{"timestamp":"2026-06-03T04:54:38.842Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /private/tmp/gw168-test\\n\\n<INSTRUCTIONS>injected config noise</INSTRUCTIONS>"},{"type":"input_text","text":"Run the shell command: echo hello > out.txt"}]}}
{"timestamp":"2026-06-03T04:54:38.843Z","type":"event_msg","payload":{"type":"user_message","message":"Run the shell command: echo hello > out.txt"}}
{"timestamp":"2026-06-03T04:54:39.000Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-06-03T04:54:41.100Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}
{"timestamp":"2026-06-03T04:54:42.000Z","type":"event_msg","payload":{"type":"agent_message","message":"I'll run the command exactly as requested; it writes `hello` into `out.txt` in the current workspace."}}
{"timestamp":"2026-06-03T04:54:42.500Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'll run the command exactly as requested; it writes `hello` into `out.txt` in the current workspace."}]}}
{"timestamp":"2026-06-03T04:54:43.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"echo hello > out.txt\\",\\"workdir\\":\\"/private/tmp/gw168-test\\",\\"yield_time_ms\\":1000,\\"max_output_tokens\\":2000}","call_id":"call_arMntF5ySYVCEfdtVSitV2Eg"}}
{"timestamp":"2026-06-03T04:54:43.200Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_arMntF5ySYVCEfdtVSitV2Eg","output":"Chunk ID: 11ef0e\\nWall time: 0.0000 seconds\\nProcess exited with code 0\\nOriginal token count: 0\\nOutput:\\n"}}
{"timestamp":"2026-06-03T04:54:44.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Done."}}
{"timestamp":"2026-06-03T04:54:44.100Z","type":"event_msg","payload":{"type":"task_complete"}}
{"timestamp":"2026-06-03T04:56:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"echo denied > nope.txt"}}
{"timestamp":"2026-06-03T04:56:00.100Z","type":"event_msg","payload":{"type":"task_started"}}
{"timestamp":"2026-06-03T04:56:02.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"echo denied > nope.txt\\",\\"workdir\\":\\"/private/tmp/gw168-test\\",\\"yield_time_ms\\":1000,\\"max_output_tokens\\":2000}","call_id":"call_MZL6mhXERQznpfRKptETIdKo"}}
{"timestamp":"2026-06-03T04:56:02.300Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_MZL6mhXERQznpfRKptETIdKo","output":"exec_command failed for `/bin/zsh -lc 'echo denied > nope.txt'`: CreateProcess { message: \\"Rejected(\\\\\\"Denied by user via Ghostwire\\\\\\")\\" }"}}
{"timestamp":"2026-06-03T04:56:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"The command was blocked by the environment: `Denied by user via Ghostwire`.\\n\\nNo file was written."}}
{"timestamp":"2026-06-03T04:56:03.100Z","type":"event_msg","payload":{"type":"task_complete"}}
"""
}
