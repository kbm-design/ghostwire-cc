//
//  CursorHookChatTests.swift
//  GhostwireTests
//
//  GW-311: Cursor's transcript is written lazily and often incompletely, so its
//  notch chat is rebuilt from the hook event stream instead of a JSONL mirror —
//  the prompt (UserPromptSubmit), each tool call (PermissionRequest gate) and
//  its output (PostToolUse), and the assistant's reply (AgentMessage). These
//  tests drive SessionStore with those events and assert the resulting chat.
//  The path is gated on agent == "cursor"; other agents still mirror their file.
//

import XCTest
@testable import Ghostwire

final class CursorHookChatTests: XCTestCase {

    private func event(
        sessionId: String,
        event: String,
        status: String = "processing",
        tool: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil,
        message: String? = nil,
        source: String = "cursor"
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: "/tmp/gw311-hookchat", event: event, status: status,
            pid: nil, tty: nil, tool: tool, toolInput: toolInput, toolUseId: toolUseId,
            notificationType: nil, message: message, source: source
        )
    }

    private func send(_ e: HookEvent) async {
        await SessionStore.shared.process(.hookReceived(e))
    }

    private func chat(_ sessionId: String) async -> [ChatHistoryItem] {
        await SessionStore.shared.session(for: sessionId)?.chatItems ?? []
    }

    private func newId(_ label: String) -> String { "gw311-\(label)-\(UUID().uuidString)" }

    // MARK: - Prose

    func testUserPromptBecomesUserChatItem() async {
        let sid = newId("prompt")
        await send(event(sessionId: sid, event: "UserPromptSubmit", message: "build the blog section"))

        let items = await chat(sid)
        XCTAssertEqual(items.count, 1)
        guard case .user(let text) = items.first?.type else { return XCTFail("expected a user item") }
        XCTAssertEqual(text, "build the blog section")
    }

    func testAgentMessageBecomesAssistantChatItem() async {
        let sid = newId("reply")
        await send(event(sessionId: sid, event: "UserPromptSubmit", message: "hi"))
        await send(event(sessionId: sid, event: "AgentMessage", message: "Here's the plan."))

        let items = await chat(sid)
        XCTAssertEqual(items.count, 2)
        guard case .assistant(let text) = items.last?.type else { return XCTFail("expected an assistant item") }
        XCTAssertEqual(text, "Here's the plan.")
    }

    func testBlankProseIsIgnored() async {
        let sid = newId("blank")
        await send(event(sessionId: sid, event: "UserPromptSubmit", message: "   \n  "))
        await send(event(sessionId: sid, event: "AgentMessage", message: nil))

        let items = await chat(sid)
        XCTAssertTrue(items.isEmpty, "whitespace/nil prose must not create empty bubbles")
    }

    // MARK: - Tools

    func testGateCreatesToolRowThenPostCompletesItWithOutput() async {
        let sid = newId("tool")
        let tuid = "tu_read_1"
        await send(event(sessionId: sid, event: "PermissionRequest", status: "waiting_for_approval",
                         tool: "Read", toolInput: ["path": AnyCodable("/tmp/App.tsx")], toolUseId: tuid))

        var items = await chat(sid)
        XCTAssertEqual(items.count, 1, "gate should create exactly one tool row")
        guard case .toolCall(let pending) = items.first?.type else { return XCTFail("expected a tool row") }
        XCTAssertEqual(pending.name, "Read")
        XCTAssertEqual(pending.status, .waitingForApproval)
        XCTAssertEqual(pending.input["path"], "/tmp/App.tsx")

        await send(event(sessionId: sid, event: "PostToolUse", tool: "Read",
                         toolUseId: tuid, message: "file contents"))

        items = await chat(sid)
        XCTAssertEqual(items.count, 1, "PostToolUse must advance the SAME row, not add one")
        guard case .toolCall(let done) = items.first?.type else { return XCTFail("expected a tool row") }
        XCTAssertEqual(done.status, .success)
        XCTAssertEqual(done.result, "file contents")
    }

    func testPostToolUseWithoutGateCreatesCompletedRow() async {
        let sid = newId("nogatetool")
        await send(event(sessionId: sid, event: "PostToolUse", tool: "Bash",
                         toolInput: ["command": AnyCodable("npm run build")],
                         toolUseId: "tu_bash_1", message: "build ok"))

        let items = await chat(sid)
        XCTAssertEqual(items.count, 1)
        guard case .toolCall(let tool) = items.first?.type else { return XCTFail("expected a tool row") }
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "build ok")
    }

    /// A duplicate PostToolUse (retry) must not regress status or overwrite the
    /// first recorded output.
    func testDuplicatePostToolUseIsIdempotent() async {
        let sid = newId("dup")
        let tuid = "tu_dup"
        await send(event(sessionId: sid, event: "PostToolUse", tool: "Read",
                         toolUseId: tuid, message: "first output"))
        await send(event(sessionId: sid, event: "PostToolUse", tool: "Read",
                         toolUseId: tuid, message: "second output"))

        let items = await chat(sid)
        XCTAssertEqual(items.count, 1)
        guard case .toolCall(let tool) = items.first?.type else { return XCTFail("expected a tool row") }
        XCTAssertEqual(tool.result, "first output", "result must be filled once, not clobbered")
    }

    // MARK: - Ordering + a full turn

    func testFullTurnReconstructsInOrder() async {
        let sid = newId("turn")
        await send(event(sessionId: sid, event: "UserPromptSubmit", message: "add a blog"))
        await send(event(sessionId: sid, event: "PermissionRequest", status: "waiting_for_approval",
                         tool: "Read", toolInput: ["path": AnyCodable("/tmp/x")], toolUseId: "t1"))
        await send(event(sessionId: sid, event: "PostToolUse", tool: "Read", toolUseId: "t1", message: "ok"))
        await send(event(sessionId: sid, event: "AgentMessage", message: "Done — added the blog."))

        let items = await chat(sid)
        XCTAssertEqual(items.count, 3, "prompt + tool + reply")
        guard case .user = items[0].type else { return XCTFail("item 0 should be user") }
        guard case .toolCall(let tool) = items[1].type else { return XCTFail("item 1 should be a tool") }
        XCTAssertEqual(tool.status, .success)
        guard case .assistant = items[2].type else { return XCTFail("item 2 should be assistant") }
    }

    // MARK: - Isolation from other agents

    /// A Claude session's UserPromptSubmit must NOT create a chat item this way —
    /// Claude's chat comes from its JSONL transcript, and doubling it here would
    /// duplicate every user turn.
    func testClaudeSessionIsUnaffected() async {
        let sid = newId("claude")
        await send(event(sessionId: sid, event: "UserPromptSubmit",
                         message: "should not appear", source: "claude"))
        await send(event(sessionId: sid, event: "AgentMessage",
                         message: "should not appear either", source: "claude"))

        let items = await chat(sid)
        XCTAssertTrue(items.isEmpty, "hook-sourced chat must be Cursor-only")
    }
}
