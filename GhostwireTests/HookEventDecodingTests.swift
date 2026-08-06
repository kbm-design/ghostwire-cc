//
//  HookEventDecodingTests.swift
//  GhostwireTests
//
//  GW-341 plus hook-hardening regression coverage.
//
//  Cursor's beforeMCPExecution sends `tool_input` JSON-encoded as a string
//  ("tool_input": "{\"nodeId\":\"1-0\"}"), not as an object. A decoder that
//  insists on an object throws and drops the whole event; for PermissionRequest
//  that means the socket closes with no verdict and the hook can fail open.
//
//  Contract pinned here: required fields (session_id, cwd, event, status) still
//  decide whether an event is valid. Optional fields are best-effort and must
//  never take an approval down.
//

import XCTest
@testable import Ghostwire

final class HookEventDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    // MARK: - Cursor string-encoded tool input

    /// Captured 2026-07-29 01:05:48 from `log stream ... category == "Hooks"`.
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

        XCTAssertEqual(event.source, "cursor")
        XCTAssertEqual(event.sessionId, "5757d4e4-3ba7-499a-beb0-4cb73a49ab98")
        XCTAssertTrue(event.expectsResponse)
        XCTAssertEqual(event.toolUseId, "ghostwire-92a57c257d9f4c1f81b8524fe09d182a")
        XCTAssertEqual(event.toolInput?["nodeId"]?.value as? String, "1-0")
    }

    /// The string-encoded object can itself contain arrays.
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

    /// A `tool_input` that is not JSON must still reach the approval surface.
    func testNonJSONStringToolInputIsPreservedNotDropped() throws {
        let event = try decode(#"""
        {"session_id": "s", "cwd": "/tmp", "event": "PermissionRequest",
         "status": "waiting_for_approval", "tool": "Shell",
         "tool_input": "rm -rf build"}
        """#)

        XCTAssertEqual(event.toolInput?["input"]?.value as? String, "rm -rf build")
    }

    // MARK: - Regressions: previously valid shapes

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

    // MARK: - Optional field drift must not drop the event

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
        XCTAssertNil(event.toolUseId)
    }

    func testOptionalGarbageDoesNotDropPermissionRequest() throws {
        let event = try decode(#"""
        {
          "session_id": "decode-session",
          "cwd": "/tmp/ghostwire",
          "event": "PermissionRequest",
          "status": "waiting_for_approval",
          "pid": {"unexpected": true},
          "tty": ["not", "a", "string"],
          "tool": "Bash",
          "tool_input": "rm -rf /tmp/example",
          "tool_use_id": 12345,
          "notification_type": {"bad": "shape"},
          "message": ["bad"],
          "source": {"bad": "shape"},
          "transcript_path": false
        }
        """#)

        XCTAssertEqual(event.sessionId, "decode-session")
        XCTAssertEqual(event.event, "PermissionRequest")
        XCTAssertEqual(event.status, "waiting_for_approval")
        XCTAssertNil(event.pid)
        XCTAssertNil(event.tty)
        XCTAssertEqual(event.tool, "Bash")
        XCTAssertEqual(event.toolInput?["input"]?.value as? String, "rm -rf /tmp/example")
        XCTAssertNil(event.toolUseId)
        XCTAssertTrue(event.expectsResponse)
    }

    // MARK: - Required fields still gate validity

    func testMissingRequiredFieldStillThrows() {
        XCTAssertThrowsError(try decode(#"{"cwd": "/tmp", "event": "Stop", "status": "idle"}"#))
    }

    func testRequiredFieldTypeMismatchStillThrows() {
        XCTAssertThrowsError(try decode(#"""
        {
          "session_id": 123,
          "cwd": "/tmp/ghostwire",
          "event": "PermissionRequest",
          "status": "waiting_for_approval"
        }
        """#))
    }
}
