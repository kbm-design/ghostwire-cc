//
//  HookEventDecodingTests.swift
//  GhostwireTests
//
//  Approval gates must not disappear just because optional hook fields drift.
//  Only session_id/cwd/event/status are allowed to make HookEvent decoding fail.
//

import XCTest
@testable import Ghostwire

final class HookEventDecodingTests: XCTestCase {

    func testOptionalGarbageDoesNotDropPermissionRequest() throws {
        let json = #"""
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
        """#

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

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

    func testJSONEncodedToolInputStringDecodesAsObject() throws {
        let json = #"""
        {
          "session_id": "decode-session",
          "cwd": "/tmp/ghostwire",
          "event": "PermissionRequest",
          "status": "waiting_for_approval",
          "tool": "Bash",
          "tool_input": "{\"command\":\"echo hi\",\"timeout\":10}"
        }
        """#

        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.toolInput?["command"]?.value as? String, "echo hi")
        XCTAssertEqual(event.toolInput?["timeout"]?.value as? Int, 10)
    }

    func testRequiredFieldFailureStillFailsDecode() {
        let json = #"""
        {
          "session_id": 123,
          "cwd": "/tmp/ghostwire",
          "event": "PermissionRequest",
          "status": "waiting_for_approval"
        }
        """#

        XCTAssertThrowsError(try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)))
    }
}
