//
//  CmuxAccessProbeTests.swift
//  GhostwireTests
//
//  GW-162: Ghostwire runs OUTSIDE cmux's process tree, so the cmux control
//  socket rejects it whenever automation.socketControlMode is the default
//  "cmuxOnly" (server accepts the connection then drops it -> EPIPE, exit 1).
//  The probe classifies that state so the UI can say WHY messaging/focus is
//  unavailable instead of silently dropping sends (the GW-162 bug).
//
//  Mode semantics verified live 2026-06-04 against cmux 0.64.x:
//  - server reports its enforced mode via `capabilities` ("access_mode")
//  - cmux.json is the authoritative config source, BUT socket mode only
//    applies at app launch (file watcher + reload-config do NOT re-arm the
//    listener) -> config-says-open + server-rejects == "restart cmux"
//

import XCTest
@testable import Ghostwire

final class CmuxAccessProbeTests: XCTestCase {

    // MARK: - Classification

    func testPingSuccessIsOk() {
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: true, socketExists: true, cliInstalled: true, configuredMode: "automation"),
            .ok
        )
    }

    func testCliMissingIsUnavailable() {
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: false, cliInstalled: false, configuredMode: nil),
            .unavailable
        )
    }

    func testNoSocketIsNotRunning() {
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: false, cliInstalled: true, configuredMode: "automation"),
            .notRunning
        )
    }

    func testRejectedWithDefaultModeIsClosedByPolicy() {
        // configuredMode nil == key absent == cmux default ("cmuxOnly")
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: true, cliInstalled: true, configuredMode: nil),
            .closedByPolicy(configuredMode: nil, needsRestart: false)
        )
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: true, cliInstalled: true, configuredMode: "cmuxOnly"),
            .closedByPolicy(configuredMode: "cmuxOnly", needsRestart: false)
        )
    }

    func testRejectedButConfigOpenNeedsRestart() {
        // Keelan's exact live state 2026-06-04: cmux.json says "automation",
        // server still enforces launch-time "cmuxOnly" -> remedy is restart,
        // not a settings change.
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: true, cliInstalled: true, configuredMode: "automation"),
            .closedByPolicy(configuredMode: "automation", needsRestart: true)
        )
        // every mode that admits external local clients counts as "open"
        for mode in ["allowAll", "openAccess", "fullOpenAccess", "full"] {
            XCTAssertEqual(
                CmuxAccessProbe.classify(pingSucceeded: false, socketExists: true, cliInstalled: true, configuredMode: mode),
                .closedByPolicy(configuredMode: mode, needsRestart: true)
            )
        }
    }

    func testRejectedWithPasswordModeIsPolicyNotRestart() {
        // password mode rejects clients that don't present the password -
        // that's a policy/credentials problem, not a restart problem
        XCTAssertEqual(
            CmuxAccessProbe.classify(pingSucceeded: false, socketExists: true, cliInstalled: true, configuredMode: "password"),
            .closedByPolicy(configuredMode: "password", needsRestart: false)
        )
    }

    // MARK: - cmux.json parsing (JSONC: // line comments are legal)

    func testParsesSocketControlMode() {
        let jsonc = """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          "schemaVersion": 1,
          "automation": {
            "socketControlMode": "automation"
          }
        }
        """
        let config = CmuxAccessProbe.parseConfig(jsonc)
        XCTAssertEqual(config.socketControlMode, "automation")
    }

    func testCommentedTemplateYieldsNoMode() {
        // The shipped cmux.json is ~260 lines of commented-out template.
        // A "socketControlMode" inside comments must NOT count (this exact
        // confusion produced a false "it's already set" during GW-162 triage).
        let jsonc = """
        {
          "$schema": "https://example.com/schema.json",
          "schemaVersion": 1,
          //   "automation" : {
          //     "socketControlMode" : "automation",
          //     "socketPassword" : "",
          //   },
        }
        """
        let config = CmuxAccessProbe.parseConfig(jsonc)
        XCTAssertNil(config.socketControlMode)
    }

    func testSlashesInsideStringsAreNotComments() {
        // "$schema": "https://..." - the // inside the URL must survive
        let jsonc = """
        {
          "$schema": "https://raw.githubusercontent.com/x/y.json",
          "automation": { "socketControlMode": "cmuxOnly" }
        }
        """
        let config = CmuxAccessProbe.parseConfig(jsonc)
        XCTAssertEqual(config.socketControlMode, "cmuxOnly")
    }

    func testParsesSocketPassword() {
        let jsonc = """
        { "automation": { "socketControlMode": "password", "socketPassword": "hunter2" } }
        """
        let config = CmuxAccessProbe.parseConfig(jsonc)
        XCTAssertEqual(config.socketPassword, "hunter2")
    }

    func testEmptyPasswordYieldsNil() {
        // schema: null or "" both mean "no password"
        let jsonc = """
        { "automation": { "socketPassword": "" } }
        """
        XCTAssertNil(CmuxAccessProbe.parseConfig(jsonc).socketPassword)
    }

    func testMalformedConfigYieldsEmpty() {
        let config = CmuxAccessProbe.parseConfig("{ not json at all")
        XCTAssertNil(config.socketControlMode)
        XCTAssertNil(config.socketPassword)
    }

    func testTrailingCommasTolerated() {
        // JSONC commonly carries trailing commas; cmux's own template does
        let jsonc = """
        {
          "automation": {
            "socketControlMode": "automation",
          },
        }
        """
        XCTAssertEqual(CmuxAccessProbe.parseConfig(jsonc).socketControlMode, "automation")
    }
}
