//
//  PlanMarkdownParserTests.swift
//  GhostwireTests
//
//  GW-322 (State C). The block layer under the plan renderer. The load-bearing
//  rule is spec §4.1: markdown may be *rendered*, but nothing may be elided —
//  so the tests care most about lines never being dropped.
//

import XCTest
@testable import Ghostwire

final class PlanMarkdownParserTests: XCTestCase {

    func testParsesHeadings() {
        let blocks = PlanMarkdownParser.parse("# Title\n## Section\n### Detail")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 3, text: "Detail")
        ])
    }

    /// A `#####…` divider is not a 7-level heading, and CommonMark caps at 6.
    func testTooManyHashesIsNotAHeading() {
        let blocks = PlanMarkdownParser.parse("####### not a heading")
        XCTAssertEqual(blocks, [.paragraph("####### not a heading")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let blocks = PlanMarkdownParser.parse("#hashtag")
        XCTAssertEqual(blocks, [.paragraph("#hashtag")])
    }

    func testParsesBulletsAndKeepsOrderedNumbering() {
        let blocks = PlanMarkdownParser.parse("""
            - first
            * second
            3. third
            4) fourth
            """)
        XCTAssertEqual(blocks, [
            .listItem(indent: 0, marker: "•", text: "first"),
            .listItem(indent: 0, marker: "•", text: "second"),
            // The author's own numbers survive — a plan that starts at 3 is not
            // silently renumbered to 1.
            .listItem(indent: 0, marker: "3.", text: "third"),
            .listItem(indent: 0, marker: "4.", text: "fourth")
        ])
    }

    func testNestedListIndent() {
        let blocks = PlanMarkdownParser.parse("- top\n  - nested\n    - deeper")
        XCTAssertEqual(blocks, [
            .listItem(indent: 0, marker: "•", text: "top"),
            .listItem(indent: 1, marker: "•", text: "nested"),
            .listItem(indent: 2, marker: "•", text: "deeper")
        ])
    }

    func testParsesFencedCodeWithLanguage() {
        let blocks = PlanMarkdownParser.parse("""
            ```sh
            echo hello
            ```
            """)
        XCTAssertEqual(blocks, [.code(language: "sh", text: "echo hello")])
    }

    /// A `#` inside a fence is a shell comment. Treating it as a heading would
    /// rewrite the command the human is agreeing to.
    func testHashInsideFenceStaysCode() {
        let blocks = PlanMarkdownParser.parse("""
            ```
            # Scratch notes file
            placeholder
            ```
            """)
        XCTAssertEqual(blocks, [.code(language: nil,
                                      text: "# Scratch notes file\nplaceholder")])
    }

    /// A plan that arrives mid-stream can carry an unclosed fence. It still has
    /// to render — the plan is never elided.
    func testUnterminatedFenceStillRenders() {
        let blocks = PlanMarkdownParser.parse("```sh\necho hello")
        XCTAssertEqual(blocks, [.code(language: "sh", text: "echo hello")])
    }

    func testParsesQuoteAndRule() {
        let blocks = PlanMarkdownParser.parse("> note\n\n---")
        XCTAssertEqual(blocks, [.quote("note"), .rule])
    }

    func testBlankLineSeparatesParagraphs() {
        let blocks = PlanMarkdownParser.parse("one\ntwo\n\nthree")
        XCTAssertEqual(blocks, [.paragraph("one\ntwo"), .paragraph("three")])
    }

    /// Spec §4.1: content elision is not allowed. Every non-blank source line
    /// must survive into some block, whatever the parser made of it.
    func testNoLineIsEverDropped() {
        let plan = """
            # Plan: Run checks and write report.md

            ## Context
            The repo needs a status pass before the report.

            ## Steps
            1. Run `npm test`
            2. Run `git status`
               - capture untracked files
            3. Write report.md

            ```sh
            npm test && git status --porcelain
            ```

            > Assumes the working tree is clean.

            ---
            Done.
            """
        let blocks = PlanMarkdownParser.parse(plan)
        let rendered = blocks.map { block -> String in
            switch block {
            case .heading(_, let t):      return t
            case .listItem(_, _, let t):  return t
            case .code(_, let t):         return t
            case .quote(let t):           return t
            case .rule:                   return "---"
            case .paragraph(let t):       return t
            }
        }.joined(separator: "\n")

        for line in plan.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("```") else { continue }
            let content = Self.stripMarkers(trimmed)
            guard !content.isEmpty else { continue }
            XCTAssertTrue(rendered.contains(content),
                          "Parser dropped source line: \(line)")
        }
    }

    /// Strip the block markers the parser lifts out of the text (`#`, bullets,
    /// `1.`/`1)`, `>`), leaving only content that must survive verbatim.
    private static func stripMarkers(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, "#>-*+".contains(first) {
            rest = rest.dropFirst()
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(".") || after.hasPrefix(")") {
                rest = after.dropFirst()
            }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
