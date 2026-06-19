//
//  HoldToTalkClassifierTests.swift
//  GhostwireTests
//
//  GW-270: the push-to-talk phase machine + flags decoder are pure, so the
//  blip/hold/combo/timeout logic and the Fn flag-bit / left-right / missed-up
//  recovery decoding are exercised here with synthetic events — no CGEventTap,
//  no real timers, no microphone.
//

import XCTest
@testable import Ghostwire

final class HoldToTalkClassifierTests: XCTestCase {

    // MARK: - Classifier

    /// A lone quick tap opens the double-tap window, then resolves to nothing.
    func testLoneTapRecordsNothing() {
        var c = HoldToTalkClassifier()
        XCTAssertEqual(c.handle(.keyDown), [.scheduleArming])
        XCTAssertEqual(c.handle(.keyUp), [.cancelArming, .scheduleDoubleTapWindow])
        XCTAssertEqual(c.handle(.doubleTapWindowFired), []) // window expires → nothing
        XCTAssertFalse(c.isEngaged)
    }

    /// Two quick taps within the window start CONTINUOUS (latched) recording; the
    /// next single press stops + routes.
    func testDoubleTapLatchesThenTapStops() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)                                   // tap 1 down
        XCTAssertEqual(c.handle(.keyUp), [.cancelArming, .scheduleDoubleTapWindow]) // tap 1 up
        XCTAssertEqual(c.handle(.keyDown), [.cancelDoubleTapWindow, .scheduleArming]) // tap 2 down
        XCTAssertEqual(c.handle(.keyUp), [.cancelArming, .beginRecording, .scheduleMaxDuration]) // tap 2 up → latched
        XCTAssertTrue(c.isEngaged)
        XCTAssertEqual(c.handle(.keyUp), [])                     // the latched tap's own release is ignored
        XCTAssertEqual(c.handle(.keyDown), [.requestStop, .cancelMaxDuration]) // next press stops + routes
        XCTAssertFalse(c.isEngaged)
    }

    /// Esc discards a latched (continuous) recording without routing.
    func testLatchedEscDiscards() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown); _ = c.handle(.keyUp)            // tap 1
        _ = c.handle(.keyDown); _ = c.handle(.keyUp)            // tap 2 → latched
        XCTAssertEqual(c.handle(.escKeyDown), [.cancelRecording, .cancelMaxDuration])
        XCTAssertFalse(c.isEngaged)
    }

    /// Tap-then-HOLD (the second press held past the arm timer) is push-to-talk, not
    /// a double-tap — it must NOT latch.
    func testTapThenHoldIsPushToTalk() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)
        XCTAssertEqual(c.handle(.keyUp), [.cancelArming, .scheduleDoubleTapWindow]) // tap 1
        XCTAssertEqual(c.handle(.keyDown), [.cancelDoubleTapWindow, .scheduleArming]) // press 2 down
        XCTAssertEqual(c.handle(.armingFired), [.beginRecording, .scheduleMaxDuration]) // held → PTT
        XCTAssertEqual(c.handle(.keyUp), [.requestStop, .cancelMaxDuration])            // release routes
    }

    /// A held key past the arm timer records, and release routes + cancels the cap.
    func testHoldRecordsThenReleaseStops() {
        var c = HoldToTalkClassifier()
        XCTAssertEqual(c.handle(.keyDown), [.scheduleArming])
        XCTAssertEqual(c.handle(.armingFired), [.beginRecording, .scheduleMaxDuration])
        XCTAssertTrue(c.isEngaged)
        XCTAssertEqual(c.handle(.keyUp), [.requestStop, .cancelMaxDuration])
        XCTAssertFalse(c.isEngaged)
    }

    /// A non-modifier key before the timer (e.g. ⌃C in a terminal) is a combo — the
    /// audio engine is never armed.
    func testComboDisarmsWithoutRecording() {
        var c = HoldToTalkClassifier()
        XCTAssertEqual(c.handle(.keyDown), [.scheduleArming])
        XCTAssertEqual(c.handle(.otherKeyDown), [.cancelArming])
        XCTAssertFalse(c.isEngaged)
        XCTAssertEqual(c.handle(.armingFired), []) // the canceled timer, if it fires
    }

    /// The safety cap force-stops if a release is ever dropped.
    func testMaxDurationForceStops() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)
        _ = c.handle(.armingFired)
        XCTAssertEqual(c.handle(.maxDurationFired), [.requestStop])
        XCTAssertFalse(c.isEngaged)
        XCTAssertEqual(c.handle(.keyUp), []) // the eventual real up is now a no-op
    }

    /// Two full gestures run independently with a clean reset between them.
    func testTwoGesturesAreIndependent() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)
        XCTAssertEqual(c.handle(.armingFired), [.beginRecording, .scheduleMaxDuration])
        XCTAssertEqual(c.handle(.keyUp), [.requestStop, .cancelMaxDuration])

        XCTAssertEqual(c.handle(.keyDown), [.scheduleArming])
        XCTAssertEqual(c.handle(.armingFired), [.beginRecording, .scheduleMaxDuration])
        XCTAssertEqual(c.handle(.keyUp), [.requestStop, .cancelMaxDuration])
    }

    /// Idle-phase noise produces nothing.
    func testIdleNoiseIgnored() {
        var c = HoldToTalkClassifier()
        XCTAssertEqual(c.handle(.keyUp), [])
        XCTAssertEqual(c.handle(.otherKeyDown), [])
        XCTAssertEqual(c.handle(.armingFired), [])
        XCTAssertEqual(c.handle(.maxDurationFired), [])
        XCTAssertFalse(c.isEngaged)
    }

    /// A slow combo — hold past the arm timer, THEN press a shortcut key — discards
    /// without routing (keeps "combos never route" true through release).
    func testKeyDownWhileRecordingCancelsWithoutRouting() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)
        _ = c.handle(.armingFired)
        XCTAssertEqual(c.handle(.otherKeyDown), [.cancelRecording, .cancelMaxDuration])
        XCTAssertFalse(c.isEngaged)
        XCTAssertEqual(c.handle(.keyUp), []) // the eventual real up is now a no-op
    }

    /// Esc during a push-to-talk hold discards without routing.
    func testEscDuringRecordingDiscards() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown)
        _ = c.handle(.armingFired)
        XCTAssertEqual(c.handle(.escKeyDown), [.cancelRecording, .cancelMaxDuration])
        XCTAssertFalse(c.isEngaged)
    }

    /// The safety cap force-stops a latched (continuous) recording too.
    func testLatchedMaxDurationForceStops() {
        var c = HoldToTalkClassifier()
        _ = c.handle(.keyDown); _ = c.handle(.keyUp)   // tap 1
        _ = c.handle(.keyDown); _ = c.handle(.keyUp)   // tap 2 → latched
        XCTAssertEqual(c.handle(.maxDurationFired), [.requestStop])
        XCTAssertFalse(c.isEngaged)
    }

    // MARK: - Decoder

    /// Bare Fn is detected by the flag edge (keycode is unreliable) and consumed so
    /// macOS's globe behavior doesn't fire.
    func testDecodeBareFnArmsAndConsumes() {
        let down = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .fn, keycodeMatchesTarget: false, targetMaskPresent: true,
            fnPresent: true, otherModifiersPresent: false,
            fnRawPresent: false, fnArmed: false, isEngaged: false)
        XCTAssertEqual(down, .init(input: .keyDown, consume: true, fnRawPresent: true, fnArmed: true))

        let up = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .fn, keycodeMatchesTarget: false, targetMaskPresent: false,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: true, fnArmed: true, isEngaged: true)
        XCTAssertEqual(up, .init(input: .keyUp, consume: true, fnRawPresent: false, fnArmed: false))

        // No edge (flag unchanged) → nothing, don't consume.
        let none = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .fn, keycodeMatchesTarget: false, targetMaskPresent: true,
            fnPresent: true, otherModifiersPresent: false,
            fnRawPresent: true, fnArmed: true, isEngaged: true)
        XCTAssertEqual(none, .init(input: nil, consume: false, fnRawPresent: true, fnArmed: true))
    }

    /// Fn pressed WITH another modifier (Cmd/Ctrl/Opt/Shift + Fn) is a system combo:
    /// not armed, NOT consumed, and its release isn't claimed either.
    func testDecodeFnWithModifierNotConsumed() {
        let down = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .fn, keycodeMatchesTarget: false, targetMaskPresent: true,
            fnPresent: true, otherModifiersPresent: true,
            fnRawPresent: false, fnArmed: false, isEngaged: false)
        XCTAssertEqual(down, .init(input: nil, consume: false, fnRawPresent: true, fnArmed: false))

        // Releasing that (un-armed) Fn passes through untouched.
        let up = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .fn, keycodeMatchesTarget: false, targetMaskPresent: false,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: true, fnArmed: false, isEngaged: false)
        XCTAssertEqual(up, .init(input: nil, consume: false, fnRawPresent: false, fnArmed: false))
    }

    /// A right modifier is matched by keycode and never consumed (so ⌃C etc. pass).
    func testDecodeRightModifierByKeycodeNeverConsumes() {
        let down = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .rightControl, keycodeMatchesTarget: true, targetMaskPresent: true,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: false, fnArmed: false, isEngaged: false)
        XCTAssertEqual(down, .init(input: .keyDown, consume: false, fnRawPresent: false, fnArmed: false))

        let up = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .rightControl, keycodeMatchesTarget: true, targetMaskPresent: false,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: false, fnArmed: false, isEngaged: true)
        XCTAssertEqual(up, .init(input: .keyUp, consume: false, fnRawPresent: false, fnArmed: false))
    }

    /// The wrong physical key (e.g. Left Control when Right is the target) is ignored
    /// while not engaged.
    func testDecodeWrongSideModifierIgnored() {
        let result = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .rightControl, keycodeMatchesTarget: false, targetMaskPresent: true,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: false, fnArmed: false, isEngaged: false)
        XCTAssertEqual(result, .init(input: nil, consume: false, fnRawPresent: false, fnArmed: false))
    }

    /// Recovery: a different modifier changed while engaged and ours is no longer
    /// held → synthesize the missed up.
    func testDecodeMissedUpRecovery() {
        let result = HoldToTalkDecoder.decodeFlagsChanged(
            targetKey: .rightControl, keycodeMatchesTarget: false, targetMaskPresent: false,
            fnPresent: false, otherModifiersPresent: false,
            fnRawPresent: false, fnArmed: false, isEngaged: true)
        XCTAssertEqual(result, .init(input: .keyUp, consume: false, fnRawPresent: false, fnArmed: false))
    }
}
