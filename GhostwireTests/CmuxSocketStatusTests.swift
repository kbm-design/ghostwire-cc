//
//  CmuxSocketStatusTests.swift
//  GhostwireTests
//
//  GW-206: the Settings -> Agents cmux row maps a CmuxAccessProbe result
//  (GW-162) to a glyph / tint-severity / status / remedy. These cover that pure
//  presentation mapping — no probe, no socket, no SwiftUI. The remedy text is
//  asserted to carry the verified-fact guidance (set Automation mode / restart;
//  cmux.json is authoritative) so a copy-paste regression is caught.
//

import XCTest
@testable import Ghostwire

final class CmuxSocketStatusTests: XCTestCase {

    private typealias P = CmuxSocketStatusPresentation

    // MARK: - Visibility (never alarm non-cmux users)

    func testUnavailableIsHidden() {
        XCTAssertFalse(P.isVisible(.unavailable))
        XCTAssertNil(P.row(for: .unavailable))
        XCTAssertNil(P.remedy(for: .unavailable))
    }

    func testEveryOtherStateIsVisible() {
        XCTAssertTrue(P.isVisible(.ok))
        XCTAssertTrue(P.isVisible(.notRunning))
        XCTAssertTrue(P.isVisible(.closedByPolicy(configuredMode: nil, needsRestart: false)))
        XCTAssertTrue(P.isVisible(.closedByPolicy(configuredMode: "automation", needsRestart: true)))
    }

    // MARK: - ok

    func testOkIsGreenWithNoRemedy() {
        let row = P.row(for: .ok)
        XCTAssertEqual(row?.severity, .ok)
        XCTAssertEqual(row?.glyph, "checkmark.circle.fill")
        XCTAssertEqual(row?.status, "Connected")
        XCTAssertNil(row?.remedy)
    }

    // MARK: - notRunning (neutral, not an error)

    func testNotRunningIsNeutralWithNoRemedy() {
        let row = P.row(for: .notRunning)
        XCTAssertEqual(row?.severity, .neutral)
        XCTAssertEqual(row?.glyph, "minus.circle")
        XCTAssertEqual(row?.status, "Not running")
        // cmux is optional — a not-running cmux must not read as a failure.
        XCTAssertNil(row?.remedy)
    }

    // MARK: - closedByPolicy: default cmuxOnly (mode change required)

    func testClosedByPolicyDefaultModeAsksToSetAutomation() {
        // needsRestart == false: the running mode rejects external apps and the
        // config doesn't name an open mode -> the user must change the mode.
        let row = P.row(for: .closedByPolicy(configuredMode: nil, needsRestart: false))
        XCTAssertEqual(row?.severity, .action)
        XCTAssertEqual(row?.glyph, "exclamationmark.triangle.fill")
        XCTAssertEqual(row?.status, "Blocked")

        let remedy = try? XCTUnwrap(row?.remedy)
        // Verified guidance: set Automation mode, and prefer the authoritative
        // cmux.json edit, then restart.
        XCTAssertTrue(remedy?.contains("Automation") ?? false)
        XCTAssertTrue(remedy?.contains("cmux.json") ?? false)
        XCTAssertTrue(remedy?.lowercased().contains("restart") ?? false)
    }

    func testPasswordModeIsAlsoModeChangeNotRestart() {
        // password mode rejects without credentials — classified needsRestart=false.
        let row = P.row(for: .closedByPolicy(configuredMode: "password", needsRestart: false))
        XCTAssertEqual(row?.severity, .action)
        XCTAssertEqual(row?.status, "Blocked")
        XCTAssertNotNil(row?.remedy)
    }

    // MARK: - closedByPolicy: open mode configured but not applied (restart)

    func testConfigOpenButRejectedAsksForRestartOnly() {
        // The launch-bound mode: cmux.json already names an open mode, so the
        // only fix is restarting cmux — NOT touching the mode again.
        let row = P.row(for: .closedByPolicy(configuredMode: "automation", needsRestart: true))
        XCTAssertEqual(row?.severity, .action)
        XCTAssertEqual(row?.glyph, "exclamationmark.triangle.fill")
        XCTAssertEqual(row?.status, "Restart needed")

        let remedy = try? XCTUnwrap(row?.remedy)
        XCTAssertTrue(remedy?.lowercased().contains("restart") ?? false)
        // Must NOT re-tell the user to change the mode (it's already correct).
        XCTAssertFalse(remedy?.contains("Socket Control Mode") ?? true)
    }

    func testAllOpenModesNeedingRestartGetRestartRemedy() {
        for mode in ["automation", "allowAll", "openAccess", "fullOpenAccess", "full"] {
            let row = P.row(for: .closedByPolicy(configuredMode: mode, needsRestart: true))
            XCTAssertEqual(row?.status, "Restart needed", "mode=\(mode)")
            XCTAssertEqual(row?.severity, .action, "mode=\(mode)")
        }
    }

    // MARK: - glyph mapping

    func testGlyphPerSeverity() {
        XCTAssertEqual(P.glyph(.ok), "checkmark.circle.fill")
        XCTAssertEqual(P.glyph(.action), "exclamationmark.triangle.fill")
        XCTAssertEqual(P.glyph(.neutral), "minus.circle")
    }

    // MARK: - remedy convenience matches row

    func testRemedyConvenienceMatchesRow() {
        let access = CmuxSocketAccess.closedByPolicy(configuredMode: nil, needsRestart: false)
        XCTAssertEqual(P.remedy(for: access), P.row(for: access)?.remedy)
    }
}
