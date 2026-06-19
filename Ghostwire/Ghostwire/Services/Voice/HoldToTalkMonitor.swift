//
//  HoldToTalkMonitor.swift
//  Ghostwire
//
//  GW-270: push-to-talk (hold-to-talk) for voice capture. A held modifier records
//  while held and routes on release — alongside the existing ⌃⇧Space TOGGLE (which
//  already covers start/stop), so the hold key is PURELY push-to-talk (no tap=toggle,
//  no latch). `KeyboardShortcuts` can't bind a pure modifier, so this owns a
//  `CGEventTap` modeled on `MediaKeyInterceptor`.
//
//  The default hold key is Right Control: a bare hold triggers no macOS behavior,
//  it exists on every keyboard, and it needs no event suppression. Fn is opt-in and
//  is the only key we CONSUME (to stop macOS's globe/dictation/emoji firing mid-hold).
//
//  Gesture model is DEBOUNCED so a modifier-combo (⌃C in a terminal) never spins up
//  the audio engine:
//    target-down → arm a ~150ms timer
//    a non-modifier key arrives first → combo → disarm (never records)
//    release before the timer → blip → disarm (never records)
//    timer fires (still held) → begin(); release → requestStop()
//  A max-duration cap force-stops if a release event is ever dropped.
//
//  The phase logic lives in `HoldToTalkClassifier` (pure, no tap/timers) so it's
//  unit-tested with synthetic event sequences. This class is the live shell:
//  CGEventTap + real timers + VoiceCaptureViewModel calls.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Defaults
import Foundation
import os

// MARK: - Hold key

/// Which modifier (if any) acts as the push-to-talk key. Right modifiers are
/// matched by virtual keycode (so left/right are distinct); Fn is matched by its
/// flag bit because the Fn keycode isn't reliable across keyboards.
enum HoldToTalkKey: String, CaseIterable, Defaults.Serializable {
    case off
    case rightControl
    case fn
    case rightCommand
    case rightOption

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn / globe (🌐)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightOption: return "Right Option (⌥)"
        }
    }

    /// Virtual keycode for the right-hand modifiers; nil for `off` and `fn`.
    var keyCode: Int64? {
        switch self {
        case .rightControl: return 0x3E
        case .rightCommand: return 0x36
        case .rightOption: return 0x3D
        case .fn, .off: return nil
        }
    }

    /// The CGEventFlags bit that is set while this modifier is held.
    var flagMask: CGEventFlags? {
        switch self {
        case .rightControl: return .maskControl
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .fn: return .maskSecondaryFn
        case .off: return nil
        }
    }
}

// MARK: - Pure classifier

/// Inputs the classifier consumes. Timestamps aren't needed: the blip-vs-hold split
/// is realized by WHEN `armingFired` arrives (the real debounce timer), not by
/// comparing times — a release in `arming` is a blip, a release in `recording` is a
/// real hold.
enum HoldToTalkInput: Equatable {
    case keyDown          // target modifier pressed
    case keyUp            // target modifier released
    case otherKeyDown     // any non-modifier key (combo signal)
    case armingFired      // the ~150ms arm timer elapsed
    case maxDurationFired // the safety cap elapsed
}

/// Side-effects the shell must perform. Pure data so tests can assert them.
enum HoldToTalkOutput: Equatable {
    case scheduleArming
    case cancelArming
    case beginRecording
    case scheduleMaxDuration
    case requestStop
    case cancelMaxDuration
}

/// The push-to-talk phase machine. Pure and `Sendable`; no tap, no timers, no VM.
struct HoldToTalkClassifier {
    private enum Phase { case idle, arming, recording }
    private var phase: Phase = .idle

    /// True while a gesture is engaged (armed or recording) — the shell uses this to
    /// synthesize a missing key-up from a flags-released recovery event.
    var isEngaged: Bool { phase != .idle }

    mutating func handle(_ input: HoldToTalkInput) -> [HoldToTalkOutput] {
        switch (phase, input) {
        // Idle: a target press arms the debounce; everything else is noise.
        case (.idle, .keyDown):
            phase = .arming
            return [.scheduleArming]

        // Arming: a real key first means a combo; an early release means a blip.
        // Either way we disarm without ever recording.
        case (.arming, .otherKeyDown), (.arming, .keyUp):
            phase = .idle
            return [.cancelArming]
        // Still held when the timer fires → start recording + arm the safety cap.
        case (.arming, .armingFired):
            phase = .recording
            return [.beginRecording, .scheduleMaxDuration]

        // Recording: release routes; the safety cap force-stops a dropped up.
        case (.recording, .keyUp):
            phase = .idle
            return [.requestStop, .cancelMaxDuration]
        case (.recording, .maxDurationFired):
            phase = .idle
            return [.requestStop]

        // Everything else (stale timers, re-downs, typing mid-dictation) is ignored.
        default:
            return []
        }
    }
}

// MARK: - Pure flags decoder

/// Decodes a `flagsChanged` event into a classifier input, kept pure so the Fn
/// flag-bit detection, left/right keycode matching, and missed-up recovery are
/// unit-tested without constructing CGEvents. The monitor supplies the booleans it
/// reads off the real event.
enum HoldToTalkDecoder {
    struct Result: Equatable {
        var input: HoldToTalkInput?
        var consume: Bool
        var fnHeld: Bool
    }

    static func decodeFlagsChanged(
        targetKey: HoldToTalkKey,
        keycodeMatchesTarget: Bool,
        targetMaskPresent: Bool,
        fnPresent: Bool,
        fnHeld: Bool,
        isEngaged: Bool
    ) -> Result {
        if targetKey == .fn {
            // Fn keycode is unreliable across keyboards — detect by the flag edge,
            // and CONSUME the transition so macOS's globe behavior doesn't fire.
            guard fnPresent != fnHeld else {
                return Result(input: nil, consume: false, fnHeld: fnHeld)
            }
            return Result(input: fnPresent ? .keyDown : .keyUp, consume: true, fnHeld: fnPresent)
        }

        // Right modifiers: match the exact physical key by keycode; never consume.
        if keycodeMatchesTarget {
            return Result(input: targetMaskPresent ? .keyDown : .keyUp, consume: false, fnHeld: fnHeld)
        }
        // Recovery: a different modifier changed and ours is no longer held while a
        // gesture is engaged — we missed the up. Synthesize it so nothing sticks.
        if isEngaged, !targetMaskPresent {
            return Result(input: .keyUp, consume: false, fnHeld: fnHeld)
        }
        return Result(input: nil, consume: false, fnHeld: fnHeld)
    }
}

// MARK: - Live monitor

@MainActor
final class HoldToTalkMonitor {
    static let shared = HoldToTalkMonitor()

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "HoldToTalk")

    /// Debounce before a held key starts recording — also the combo/blip window.
    private let armingDelay: TimeInterval = 0.15
    /// Safety cap: force-stop if a release is ever lost so recording can't stick.
    private let maxHoldDuration: TimeInterval = 60

    /// The currently-armed key. `.off` ⇒ the tap is not running.
    private var targetKey: HoldToTalkKey = .off
    private var classifier = HoldToTalkClassifier()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Guards the async window in start() (the Accessibility await) so two rapid
    /// reconfigure() calls can't each create a tap and leak one.
    private var startInFlight = false

    private var armingWork: DispatchWorkItem?
    private var maxDurationWork: DispatchWorkItem?

    /// Last-seen Fn flag state, for edge detection (the Fn keycode is unreliable).
    private var fnHeld = false

    /// Set by GhostwireApp: wire the per-display reveal/open/close callbacks for the
    /// notch under the mouse BEFORE begin(), so the hold path routes like the toggle.
    var prepareForGesture: @MainActor () -> Void = {}

    private init() {}

    // MARK: Configuration

    /// Read Defaults and bring the tap in line: stop when voice is off or the key is
    /// `.off`, (re)start otherwise. A key change while already running just swaps the
    /// target — no tap teardown (the event mask is identical).
    func reconfigure(promptIfNeeded: Bool = false) {
        let enabled = Defaults[.voiceCaptureEnabled]
        let key = HoldToTalkKey(rawValue: Defaults[.voiceHoldToTalkKey]) ?? .off
        let desired: HoldToTalkKey = enabled ? key : .off

        guard desired != .off else {
            if eventTap != nil { stop() }
            targetKey = .off
            return
        }

        targetKey = desired
        if eventTap == nil {
            Task { await start(promptIfNeeded: promptIfNeeded) }
        }
        // else: already running — the callback reads `targetKey` live, nothing to do.
    }

    // MARK: Tap lifecycle (mirrors MediaKeyInterceptor)

    private func start(promptIfNeeded: Bool) async {
        guard eventTap == nil, !startInFlight, targetKey != .off else { return }
        startInFlight = true
        defer { startInFlight = false }

        let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        if !authorized {
            if promptIfNeeded {
                let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                guard granted else { return }
            } else {
                return // silent at launch; the Settings toggle prompts explicitly
            }
        }
        // Re-check: the user may have flipped it off during the await.
        guard eventTap == nil, targetKey != .off else { return }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passRetained(cgEvent) }
                let monitor = Unmanaged<HoldToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // The source is on the main run loop, so the callback runs on main.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.handleTapDisabled() }
                    return Unmanaged.passRetained(cgEvent)
                }
                let consume = MainActor.assumeIsolated { monitor.handle(type: type, event: cgEvent) }
                return consume ? nil : Unmanaged.passRetained(cgEvent)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            Self.logger.error("hold-to-talk: failed to create event tap")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.notice("hold-to-talk: tap started (\(self.targetKey.rawValue, privacy: .public))")
    }

    private func stop() {
        cancelTimers()
        classifier = HoldToTalkClassifier()
        fnHeld = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        Self.logger.notice("hold-to-talk: tap stopped")
    }

    private func handleTapDisabled() {
        // The system disabled us (slow callback / heavy input). Re-enable, and since
        // we may have missed a key-up, force-stop any engaged gesture.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        if classifier.isEngaged {
            process(classifier.handle(.keyUp))
        }
        Self.logger.notice("hold-to-talk: tap re-enabled after disable")
    }

    // MARK: Event handling

    /// Translate a CGEvent into a classifier input. Returns whether to CONSUME the
    /// event (only ever true for a bare-Fn flagsChanged when Fn is the key).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            // Any keyDown is a non-modifier key (modifiers arrive via flagsChanged).
            process(classifier.handle(.otherKeyDown))
            return false

        case .flagsChanged:
            guard let mask = targetKey.flagMask else { return false }
            let flags = event.flags
            let result = HoldToTalkDecoder.decodeFlagsChanged(
                targetKey: targetKey,
                keycodeMatchesTarget: targetKey.keyCode == event.getIntegerValueField(.keyboardEventKeycode),
                targetMaskPresent: flags.contains(mask),
                fnPresent: flags.contains(.maskSecondaryFn),
                fnHeld: fnHeld,
                isEngaged: classifier.isEngaged
            )
            fnHeld = result.fnHeld
            if let input = result.input {
                process(classifier.handle(input))
            }
            return result.consume

        default:
            return false
        }
    }

    // MARK: Output processing

    private func process(_ outputs: [HoldToTalkOutput]) {
        for output in outputs {
            switch output {
            case .scheduleArming:
                scheduleArming()
            case .cancelArming:
                armingWork?.cancel()
                armingWork = nil
            case .beginRecording:
                beginRecording()
            case .scheduleMaxDuration:
                scheduleMaxDuration()
            case .requestStop:
                maxDurationWork?.cancel()
                maxDurationWork = nil
                Task { await VoiceCaptureViewModel.shared.requestStop() }
            case .cancelMaxDuration:
                maxDurationWork?.cancel()
                maxDurationWork = nil
            }
        }
    }

    private func beginRecording() {
        prepareForGesture() // wire reveal/open/close for the notch under the mouse
        Self.logger.notice("hold-to-talk: begin")
        Task { await VoiceCaptureViewModel.shared.begin() }
    }

    private func scheduleArming() {
        armingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.armingWork = nil
            self.process(self.classifier.handle(.armingFired))
        }
        armingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + armingDelay, execute: work)
    }

    private func scheduleMaxDuration() {
        maxDurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.maxDurationWork = nil
            Self.logger.notice("hold-to-talk: max-duration force-stop")
            self.process(self.classifier.handle(.maxDurationFired))
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxHoldDuration, execute: work)
    }

    private func cancelTimers() {
        armingWork?.cancel()
        armingWork = nil
        maxDurationWork?.cancel()
        maxDurationWork = nil
    }
}
