//
//  ToolCallRawInputTests.swift
//  GhostwireTests
//
//  GW-144/GW-139 full-raw rule: transcript tool rows must show every
//  input shape verbatim — MCPToolFormatter.formatArgs truncates values
//  (30 chars) and caps args (3), so full-raw bypasses it entirely.
//

import XCTest
@testable import Ghostwire

final class ToolCallRawInputTests: XCTestCase {

    func testRawInputKeepsLongValuesUntruncated() {
        let command = String(repeating: "x", count: 500)

        let rendered = ToolCallView.rawInput(["command": command])

        XCTAssertEqual(rendered, "command: \(command)")
        XCTAssertFalse(rendered.contains("..."))
    }

    func testRawInputRendersEveryKeySorted() {
        // formatArgs would cap this at 3 args + "..."; full-raw must not.
        let input = [
            "delta": "4", "alpha": "1", "charlie": "3", "bravo": "2", "echo": "5",
        ]

        let rendered = ToolCallView.rawInput(input)

        XCTAssertEqual(
            rendered,
            "alpha: 1\nbravo: 2\ncharlie: 3\ndelta: 4\necho: 5"
        )
    }

    func testMCPShapedInputSurvivesFullRawIntact() {
        // The redo spec's exact scenario: >3 args AND >30-char values.
        // formatArgs(input) would emit 3 args with 30-char+ellipsis values;
        // rawInput must contain every key and every full value, no ellipses.
        let long = { (tag: String) in "\(tag)-" + String(repeating: "v", count: 64) }
        let input = [
            "query": long("q"),
            "collection": long("c"),
            "filter": long("f"),
            "intent": long("i"),
            "minScore": "0.5",
        ]

        let rendered = ToolCallView.rawInput(input)

        for (key, value) in input {
            XCTAssertTrue(rendered.contains("\(key): \(value)"), "missing full \(key)")
        }
        XCTAssertFalse(rendered.contains("..."))
        // Sanity: the inline formatter really is lossy for this input —
        // guards against formatArgs becoming lossless and this test moot.
        let inline = MCPToolFormatter.formatArgs(input)
        XCTAssertTrue(inline.contains("..."))
    }

    func testRawInputEmptyIsEmpty() {
        XCTAssertEqual(ToolCallView.rawInput([:]), "")
    }
}
