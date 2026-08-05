//
//  ExitPlanModePayloadTests.swift
//  GhostwireTests
//
//  GW-322 (State C). Fixtures are real payloads captured from live Claude Code
//  2.1.222 across 8 driven PTY runs, plus the historical `allowedPrompts` shape
//  from the GW-318 spike. Not invented shapes.
//  See docs/interaction-model-payloads.md.
//

import XCTest
@testable import Ghostwire

final class ExitPlanModePayloadTests: XCTestCase {

    /// Verbatim `tool_input` from a live PermissionRequest capture (GW-322 run 1).
    /// This exact payload also arrives on the preceding PreToolUse, unchanged.
    private func planPayload() -> [String: AnyCodable] {
        [
            "plan": AnyCodable("""
                # Plan: Add header comment to notes.txt

                ## Context
                `notes.txt` currently contains only a placeholder line.

                ## Change
                Prepend a single line to `notes.txt`:

                ```
                # Scratch notes file
                placeholder
                ```

                ## Verification
                `cat notes.txt` to confirm the header line appears first.
                """),
            "planFilePath": AnyCodable(
                "/Users/keelan/.claude/plans/plan-a-tiny-change-rustling-tiger.md")
        ]
    }

    /// The historical shape carrying pre-authorized commands (GW-318, 5/6 calls).
    private func planWithGrantsPayload() -> [String: AnyCodable] {
        [
            "plan": AnyCodable("# Add a README\n\nCreate the scaffold."),
            "planFilePath": AnyCodable("/Users/keelan/.claude/plans/drifting-quiche.md"),
            "allowedPrompts": AnyCodable([
                ["tool": "Bash", "prompt": "create directories and files under trading-desk/"],
                ["tool": "Bash", "prompt": "run the test suite"]
            ])
        ]
    }

    // MARK: - Parsing

    func testParsesLivePlanPayload() {
        let request = ExitPlanModeRequest(toolInput: planPayload())
        XCTAssertNotNil(request)
        XCTAssertTrue(request?.plan.hasPrefix("# Plan: Add header comment") == true)
        XCTAssertEqual(request?.planFilePath,
                       "/Users/keelan/.claude/plans/plan-a-tiny-change-rustling-tiger.md")
        // Absent in all 5 ExitPlanMode calls captured on 2.1.222.
        XCTAssertEqual(request?.allowedPrompts, [])
    }

    func testParsesAllowedPrompts() {
        let request = ExitPlanModeRequest(toolInput: planWithGrantsPayload())
        XCTAssertEqual(request?.allowedPrompts.count, 2)
        XCTAssertEqual(request?.allowedPrompts.first?.tool, "Bash")
        XCTAssertEqual(request?.allowedPrompts.first?.prompt,
                       "create directories and files under trading-desk/")
    }

    /// `planFilePath` is optional: a missing path hides nothing, because the plan
    /// text is the content being reviewed.
    func testParsesWithoutPlanFilePath() {
        let request = ExitPlanModeRequest(toolInput: ["plan": AnyCodable("# Just a plan")])
        XCTAssertNotNil(request)
        XCTAssertNil(request?.planFilePath)
    }

    func testRejectsMissingPlan() {
        XCTAssertNil(ExitPlanModeRequest(toolInput: [
            "planFilePath": AnyCodable("/tmp/x.md")
        ]))
    }

    func testRejectsEmptyPlan() {
        XCTAssertNil(ExitPlanModeRequest(toolInput: ["plan": AnyCodable("")]))
    }

    /// The security rule: a partially-parsed grant list would let the user
    /// authorize a command they were never shown, so the whole payload is
    /// rejected and the caller falls back to the verbatim approval bar.
    func testRejectsPartiallyParsableAllowedPrompts() {
        let payload: [String: AnyCodable] = [
            "plan": AnyCodable("# Plan"),
            "allowedPrompts": AnyCodable([
                ["tool": "Bash", "prompt": "rm -rf build/"],
                ["tool": "Bash"]  // no prompt — unreadable
            ])
        ]
        XCTAssertNil(ExitPlanModeRequest(toolInput: payload))
    }

    func testRejectsNonListAllowedPrompts() {
        let payload: [String: AnyCodable] = [
            "plan": AnyCodable("# Plan"),
            "allowedPrompts": AnyCodable("Bash: do a thing")
        ]
        XCTAssertNil(ExitPlanModeRequest(toolInput: payload))
    }

    // MARK: - Codable (spec §8 gateway/phone readiness)

    func testRoundTripsThroughJSON() throws {
        let request = try XCTUnwrap(ExitPlanModeRequest(toolInput: planWithGrantsPayload()))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ExitPlanModeRequest.self, from: data)
        XCTAssertEqual(decoded, request)
    }

    // MARK: - Revise message

    func testReviseMessageCarriesFeedbackVerbatim() {
        let request = try? XCTUnwrap(ExitPlanModeRequest(toolInput: planPayload()))
        let message = request?.reviseMessage(feedback: "skip the chmod, use sh build.sh")
        XCTAssertTrue(message?.contains("skip the chmod, use sh build.sh") == true)
        XCTAssertTrue(message?.contains("Revise the plan") == true)
    }

    func testReviseMessageTrimsFeedback() {
        let request = try? XCTUnwrap(ExitPlanModeRequest(toolInput: planPayload()))
        let message = request?.reviseMessage(feedback: "  keep it to one file  \n")
        XCTAssertTrue(message?.contains("changes: keep it to one file Revise") == true)
    }

    /// Empty feedback must never read as an accepted plan — the model has to know
    /// it was not accepted, and that it should ask rather than re-present blind.
    func testEmptyFeedbackStillDeniesClearly() {
        let request = try? XCTUnwrap(ExitPlanModeRequest(toolInput: planPayload()))
        let message = try? XCTUnwrap(request?.reviseMessage(feedback: "   "))
        XCTAssertTrue(message?.contains("did not accept") == true)
    }
}
