//
//  PermissionOpenRuleTests.swift
//  GhostwireTests
//
//  GW-209: the new-permission gate splits into two effects — the passive ALERT
//  (glow + haptic + record) and the notch OPEN — decided purely from
//  (mode, notchClosed, paneFocused). These cover the full
//  3 modes × pane-focused × notch-closed matrix. No bridge, no Combine, no
//  SwiftUI. Pins the contract Keelan locked: a hidden lane must still alert even
//  when other terminals are on screen, and Never suppresses only the open.
//

import XCTest
@testable import Ghostwire

final class PermissionOpenRuleTests: XCTestCase {

    private typealias Rule = PermissionOpenRule

    private func decide(
        _ mode: PermissionAutoOpenMode,
        notchClosed: Bool,
        paneFocused: Bool
    ) -> PermissionOpenRule.Decision {
        Rule.decide(mode: mode, notchClosed: notchClosed, paneFocused: paneFocused)
    }

    // MARK: - Smart: per-session visibility

    func testSmartPaneNotFocusedNotchClosedOpensAndAlerts() {
        // The headline case: a hidden lane pings while cmux is on screen.
        let d = decide(.smart, notchClosed: true, paneFocused: false)
        XCTAssertTrue(d.alert)
        XCTAssertTrue(d.open)
    }

    func testSmartPaneNotFocusedNotchOpenAlertsButDoesNotOpen() {
        // Notch already open: still alert, but don't re-open (precondition).
        let d = decide(.smart, notchClosed: false, paneFocused: false)
        XCTAssertTrue(d.alert)
        XCTAssertFalse(d.open)
    }

    func testSmartPaneFocusedNotchClosedStaysSilent() {
        // You're staring at the asking pane — no glow, no open.
        let d = decide(.smart, notchClosed: true, paneFocused: true)
        XCTAssertFalse(d.alert)
        XCTAssertFalse(d.open)
    }

    func testSmartPaneFocusedNotchOpenStaysSilent() {
        let d = decide(.smart, notchClosed: false, paneFocused: true)
        XCTAssertFalse(d.alert)
        XCTAssertFalse(d.open)
    }

    // MARK: - Always: open on every permission (notch-closed still required)

    func testAlwaysPaneNotFocusedNotchClosedOpensAndAlerts() {
        let d = decide(.always, notchClosed: true, paneFocused: false)
        XCTAssertTrue(d.alert)
        XCTAssertTrue(d.open)
    }

    func testAlwaysPaneFocusedNotchClosedOpensWithoutAlert() {
        // Always forces the open even when you're on the pane; but there's
        // nothing to alert about (you can see it), so the glow stays off.
        let d = decide(.always, notchClosed: true, paneFocused: true)
        XCTAssertFalse(d.alert)
        XCTAssertTrue(d.open)
    }

    func testAlwaysNotchOpenNeverReOpens() {
        // The notch-closed precondition holds for Always too.
        let focused = decide(.always, notchClosed: false, paneFocused: true)
        XCTAssertFalse(focused.open)
        XCTAssertFalse(focused.alert)

        let hidden = decide(.always, notchClosed: false, paneFocused: false)
        XCTAssertFalse(hidden.open)
        XCTAssertTrue(hidden.alert)
    }

    // MARK: - Never: never auto-open; alert still follows the Smart rule

    func testNeverNeverOpens() {
        for notchClosed in [true, false] {
            for paneFocused in [true, false] {
                let d = decide(.never, notchClosed: notchClosed, paneFocused: paneFocused)
                XCTAssertFalse(
                    d.open,
                    "Never must never open (notchClosed=\(notchClosed), paneFocused=\(paneFocused))"
                )
            }
        }
    }

    func testNeverStillAlertsWhenPaneNotFocused() {
        // Never only suppresses the OPEN — the glow/haptic/record still fire
        // by the Smart visibility rule.
        let hidden = decide(.never, notchClosed: true, paneFocused: false)
        XCTAssertTrue(hidden.alert)
        XCTAssertFalse(hidden.open)

        let focused = decide(.never, notchClosed: true, paneFocused: true)
        XCTAssertFalse(focused.alert)
        XCTAssertFalse(focused.open)
    }
}
