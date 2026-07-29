//
//  HookEventDecodingTests.swift
//  GhostwireTests
//
//  GW-341: Cursor's beforeMCPExecution sends `tool_input` JSON-ENCODED AS A
//  STRING ("tool_input": "{\"nodeId\":\"1-0\"}"), not as an object. A decoder
//  that insists on an object throws and the whole event is dropped — and for a
//  PermissionRequest that means the socket closes with no verdict, so the hook
//  fails open and the tool runs without the human ever seeing it.
//
//  The contract these tests pin down: required fields (session_id, cwd, event,
//  status) still decide whether an event is valid; every OPTIONAL field is
//  best-effort and must never take an approval down with it.
//

import XCTest
@testable import Ghostwire

final class HookEventDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    // MARK: - The GW-341 payload, verbatim from the hook log

    /// Captured 2026-07-29 01:05:48 from `log stream … category == "Hooks"`.
    func testCursorMCPGateWithStringEncodedToolInputDecodes() throws {
        let event = try decode(#"""
        {"session_id": "5757d4e4-3ba7-499a-beb0-4cb73a49ab98",
         "cwd": "/Users/keelanmiskell/Desktop/Coding/portfolio-website",
         "event": "PermissionRequest", "pid": 12983, "tty": null, "source": "cursor",
         "transcript_path": "/Users/keelanmiskell/.cursor/projects/x/agent-transcripts/y/y.jsonl",
         "cmux_workspace": "workspace:12", "cmux_surface": "surface:25",
         "status": "waiting_for_approval", "tool": "get_screenshot",
         "tool_input": "{\"nodeId\":\"1-0\"}",
         "tool_use_id": "ghostwire-92a57c257d9f4c1f81b8524fe09d182a"}
        """#)

        // Identity — the half the user sees as a wrong-coloured tag.
        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.sessionId, "5757d4e4-3ba7-499a-beb0-4cb73a49ab98")

        // The approval half: the event has to survive AND stay decidable.
        XCTAssertTrue(event.expectsResponse)
        XCTAssertEqual(event.toolUseId, "ghostwire-92a57c257d9f4c1f81b8524fe09d182a")
        XCTAssertEqual(event.toolInput?["nodeId"]?.value as? String, "1-0")
    }

    /// The string-encoded object can itself contain arrays (get_font_family_info).
    func testStringEncodedToolInputWithNestedArrayDecodes() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp", "event": "PermissionRequest",
         "status": "waiting_for_approval", "source": "cursor",
         "tool": "get_font_family_info",
         "tool_input": "{\"familyNames\":[\"Geist\",\"Departure Mono\"]}"}
        """#)

        let names = event.toolInput?["familyNames"]?.value as? [Any]
        XCTAssertEqual(names?.count, 2)
        XCTAssertEqual(names?.first as? String, "Geist")
    }

    /// GW-139 rule: the human approves what they can see. A `tool_input` that
    /// isn't JSON at all must still reach the approval surface, not vanish.
    func testNonJSONStringToolInputIsPreservedNotDropped() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp", "event": "PermissionRequest",
         "status": "waiting_for_approval", "tool": "Shell",
         "tool_input": "rm -rf build"}
        """#)

        XCTAssertEqual(event.toolInput?["input"]?.value as? String, "rm -rf build")
    }

    // MARK: - Regressions: the shapes that already worked

    func testClaudeObjectToolInputStillDecodes() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp/repo", "event": "PreToolUse",
         "status": "running_tool", "source": "claude", "tool": "Bash",
         "tool_input": {"command": "ls -la", "timeout": 5000},
         "tool_use_id": "toolu_01"}
        """#)

        XCTAssertEqual(event.toolInput?["command"]?.value as? String, "ls -la")
        XCTAssertEqual(event.toolInput?["timeout"]?.value as? Int, 5000)
        XCTAssertEqual(event.source, "claude")
    }

    func testAbsentToolInputDecodesToNil() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp", "event": "Stop", "status": "waiting_for_input",
         "source": "cursor"}
        """#)

        XCTAssertNil(event.toolInput)
        XCTAssertEqual(event.source, "cursor")
    }

    // MARK: - No optional field may take the whole event down

    /// The generalised GW-341 lesson: shape drift in any optional field costs
    /// at most that field. Anything stricter silently drops approvals.
    func testUnexpectedlyShapedOptionalFieldsDoNotDropTheEvent() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp", "event": "PermissionRequest",
         "status": "waiting_for_approval", "source": "cursor", "tool": "X",
         "pid": "12983", "tty": 7, "tool_use_id": 42, "message": {"text": "hi"},
         "tool_input": {"a": 1}}
        """#)

        XCTAssertTrue(event.expectsResponse)
        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.toolInput?["a"]?.value as? Int, 1)
        XCTAssertNil(event.pid)
        XCTAssertNil(event.tty)
    }

    /// Required fields still gate validity — a payload with no event name is
    /// genuinely unusable and should fail loudly rather than half-register.
    func testMissingRequiredFieldStillThrows() {
        XCTAssertThrowsError(try decode(#"{"cwd": "/tmp", "event": "Stop", "status": "idle"}"#))
    }
}
