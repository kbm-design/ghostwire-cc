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
//  GW-444: the test host is the live app, so every Defaults write here is real.
//  See `withRestoredGhostModePref` for why a naive save/restore is not enough.
//

import AppKit
import Defaults
import XCTest

@testable import Ghostwire

final class GhostModeTests: XCTestCase {

    /// Runs `body` and restores the key to *exactly* the state it was in —
    /// including "no stored value at all".
    ///
    /// A plain `let saved = Defaults[key]` / `defer { Defaults[key] = saved }`
    /// looks like save-restore but isn't: the read returns the *effective*
    /// value, and `Defaults`' setter always writes. So on a machine that had
    /// never touched the toggle, the restore materialises a stored value out of
    /// the default. Because the test host is the live app (GW-444), that would
    /// permanently opt this machine out of any future change to the shipped
    /// default — the exact kind of change GW-463 just made.
    private func withRestoredGhostModePref(_ body: () -> Void) {
        let key = Defaults.Keys.hideFromScreenRecording
        let hadStoredValue = UserDefaults.standard.object(forKey: key.name) != nil
        let saved = Defaults[key]
        defer {
            if hadStoredValue {
                Defaults[key] = saved
            } else {
                Defaults.reset(key)
            }
        }
        body()
    }

    func testSharingTypeIsNoneWhenEnabled() {
        withRestoredGhostModePref {
            Defaults[.hideFromScreenRecording] = true

            XCTAssertTrue(GhostMode.isEnabled)
            XCTAssertEqual(GhostMode.sharingType, .none)
        }
    }

    func testSharingTypeIsReadOnlyWhenDisabled() {
        withRestoredGhostModePref {
            Defaults[.hideFromScreenRecording] = false

            XCTAssertFalse(GhostMode.isEnabled)
            // Not `.readWrite` — deprecated as of macOS 15.
            XCTAssertEqual(GhostMode.sharingType, .readOnly)
        }
    }

    func testApplySetsSharingTypeOnTheWindow() {
        withRestoredGhostModePref {
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
    }

    func testGhostModeShipsOn() {
        XCTAssertTrue(Defaults.Keys.hideFromScreenRecording.defaultValue)
    }
}
