//
//  GhostModeTests.swift
//  GhostwireTests
//
//  GW-463: ghost mode maps the `hideFromScreenRecording` toggle onto
//  `NSWindow.sharingType`. There is nothing to test about the windows
//  themselves — whether `.none` actually defeats a ScreenCaptureKit recorder is
//  a property of the OS and was measured by hand — so this pins the two things
//  code can get wrong: the mapping, and the shipped default.
//
//  The "off" assertion is the real regression guard. The inherited Buddi code
//  used `.readWrite`, which macOS 15 deprecated in favour of `.readOnly`; this
//  fails if it comes back.
//
//  GW-444: the test host is the live app, so every Defaults write here is real
//  and is restored in a `defer`.
//

import AppKit
import Defaults
import XCTest

@testable import Ghostwire

final class GhostModeTests: XCTestCase {

    func testSharingTypeIsNoneWhenEnabled() {
        let saved = Defaults[.hideFromScreenRecording]
        defer { Defaults[.hideFromScreenRecording] = saved }

        Defaults[.hideFromScreenRecording] = true

        XCTAssertTrue(GhostMode.isEnabled)
        XCTAssertEqual(GhostMode.sharingType, .none)
    }

    func testSharingTypeIsReadOnlyWhenDisabled() {
        let saved = Defaults[.hideFromScreenRecording]
        defer { Defaults[.hideFromScreenRecording] = saved }

        Defaults[.hideFromScreenRecording] = false

        XCTAssertFalse(GhostMode.isEnabled)
        // Not `.readWrite` — deprecated as of macOS 15.
        XCTAssertEqual(GhostMode.sharingType, .readOnly)
    }

    func testApplySetsSharingTypeOnTheWindow() {
        let saved = Defaults[.hideFromScreenRecording]
        defer { Defaults[.hideFromScreenRecording] = saved }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )

        Defaults[.hideFromScreenRecording] = true
        GhostMode.apply(to: window)
        XCTAssertEqual(window.sharingType, .none)

        Defaults[.hideFromScreenRecording] = false
        GhostMode.apply(to: window)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    func testGhostModeShipsOn() {
        XCTAssertTrue(Defaults.Keys.hideFromScreenRecording.defaultValue)
    }
}
