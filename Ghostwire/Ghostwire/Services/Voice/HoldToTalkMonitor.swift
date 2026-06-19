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

/// Inputs the classifier consumes. Timestamps aren't needed: the blip-vs-hold and
/// the double-tap splits are realized by WHICH timer fires (the real arm timer and
/// double-tap window), not by comparing times.
enum HoldToTalkInput: Equatable {
    case keyDown             // target modifier pressed
    case keyUp               // target modifier released
    case otherKeyDown        // any non-modifier, non-Esc key (combo signal)
    case escKeyDown          // Escape — cancels an active recording (discard)
    case armingFired         // the ~150ms arm timer elapsed
    case doubleTapWindowFired // the double-tap window expired (single tap → nothing)
    case maxDurationFired    // the safety cap elapsed
}

/// Side-effects the shell must perform. Pure data so tests can assert them.
enum HoldToTalkOutput: Equatable {
    case scheduleArming
    case cancelArming
    case scheduleDoubleTapWindow
    case cancelDoubleTapWindow
    case beginRecording
    case scheduleMaxDuration
    case requestStop
    /// Discard the active recording WITHOUT routing (a combo or Esc mid-recording).
    case cancelRecording
    case cancelMaxDuration
}

/// The push-to-talk + double-tap phase machine. Pure and `Sendable`; no tap, no
/// timers, no VM. Gesture vocabulary on the configured key:
///   • hold (past the arm timer) → push-to-talk; release routes.
///   • quick tap, then quick tap (within the double-tap window) → start CONTINUOUS
///     (latched) recording; a later single press stops+routes, Esc discards.
///   • a lone quick tap → nothing.
///   • a non-modifier key (or Esc) mid-gesture → combo/abort, never routes.
struct HoldToTalkClassifier {
    private enum Phase {
        case idle
        case armingFirst       // first press down, waiting arm timer or release
        case recording         // push-to-talk active (held)
        case awaitingSecondTap // first tap released, watching for a second tap
        case armingSecond      // second press down — quick release = double-tap, hold = PTT
        case latched           // continuous recording from a double-tap
    }
    private var phase: Phase = .idle

    /// True while a gesture is engaged — the shell uses this to synthesize a missing
    /// key-up from a flags-released recovery event.
    var isEngaged: Bool { phase != .idle }

    mutating func handle(_ input: HoldToTalkInput) -> [HoldToTalkOutput] {
        switch (phase, input) {
        // Idle: a target press arms the debounce; everything else is noise.
        case (.idle, .keyDown):
            phase = .armingFirst
            return [.scheduleArming]

        // First arming: a real key/Esc means a combo; an early release is a tap —
        // begin watching for a second tap (a lone tap resolves to nothing).
        case (.armingFirst, .otherKeyDown), (.armingFirst, .escKeyDown):
            phase = .idle
            return [.cancelArming]
        case (.armingFirst, .keyUp):
            phase = .awaitingSecondTap
            return [.cancelArming, .scheduleDoubleTapWindow]
        case (.armingFirst, .armingFired):
            phase = .recording
            return [.beginRecording, .scheduleMaxDuration]

        // Push-to-talk: release routes; a combo/Esc discards; the cap force-stops.
        case (.recording, .keyUp):
            phase = .idle
            return [.requestStop, .cancelMaxDuration]
        case (.recording, .otherKeyDown), (.recording, .escKeyDown):
            phase = .idle
            return [.cancelRecording, .cancelMaxDuration]
        case (.recording, .maxDurationFired):
            phase = .idle
            return [.requestStop]

        // Between taps: a second press starts the second arm; expiry/other = lone tap.
        case (.awaitingSecondTap, .keyDown):
            phase = .armingSecond
            return [.cancelDoubleTapWindow, .scheduleArming]
        case (.awaitingSecondTap, .doubleTapWindowFired):
            phase = .idle
            return []
        case (.awaitingSecondTap, .otherKeyDown), (.awaitingSecondTap, .escKeyDown):
            phase = .idle
            return [.cancelDoubleTapWindow]

        // Second press: a quick release confirms the double-tap → latched recording;
        // holding it past the arm timer was really a (delayed) push-to-talk.
        case (.armingSecond, .keyUp):
            phase = .latched
            return [.cancelArming, .beginRecording, .scheduleMaxDuration]
        case (.armingSecond, .armingFired):
            phase = .recording
            return [.beginRecording, .scheduleMaxDuration]
        case (.armingSecond, .otherKeyDown), (.armingSecond, .escKeyDown):
            phase = .idle
            return [.cancelArming]

        // Latched: the next press stops + routes; Esc discards; the cap force-stops.
        // (The double-tap's own release lands here as a keyUp and is ignored.)
        case (.latched, .keyDown):
            phase = .idle
            return [.requestStop, .cancelMaxDuration]
        case (.latched, .escKeyDown):
            phase = .idle
            return [.cancelRecording, .cancelMaxDuration]
        case (.latched, .maxDurationFired):
            phase = .idle
            return [.requestStop]

        // Everything else (stale timers, the latched tap's release, re-downs) ignored.
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
        /// Raw physical Fn state (edge detection — Fn keycode is unreliable).
        var fnRawPresent: Bool
        /// Whether we armed a BARE-Fn talk hold (so the release is ours to emit).
        var fnArmed: Bool
    }

    static func decodeFlagsChanged(
        targetKey: HoldToTalkKey,
        keycodeMatchesTarget: Bool,
        targetMaskPresent: Bool,
        fnPresent: Bool,
        otherModifiersPresent: Bool,
        fnRawPresent: Bool,
        fnArmed: Bool,
        isEngaged: Bool
    ) -> Result {
        if targetKey == .fn {
            // Act only on a real Fn press/release edge (ignore other-modifier churn).
            guard fnPresent != fnRawPresent else {
                return Result(input: nil, consume: false, fnRawPresent: fnRawPresent, fnArmed: fnArmed)
            }
            if fnPresent {
                // Fn down. Only a BARE Fn is a talk gesture we arm + consume (consume
                // so macOS's globe/dictation default doesn't fire). Fn pressed WITH
                // another modifier is a system combo — leave it entirely untouched.
                if otherModifiersPresent {
                    return Result(input: nil, consume: false, fnRawPresent: true, fnArmed: false)
                }
                return Result(input: .keyDown, consume: true, fnRawPresent: true, fnArmed: true)
            }
            // Fn up. Emit (and consume) the release only if we'd armed a bare-Fn hold.
            guard fnArmed else {
                return Result(input: nil, consume: false, fnRawPresent: false, fnArmed: false)
            }
            return Result(input: .keyUp, consume: true, fnRawPresent: false, fnArmed: false)
        }

        // Right modifiers: match the exact physical key by keycode; never consume.
        if keycodeMatchesTarget {
            return Result(input: targetMaskPresent ? .keyDown : .keyUp,
                          consume: false, fnRawPresent: fnRawPresent, fnArmed: fnArmed)
        }
        // Recovery: a different modifier changed and ours is no longer held while a
        // gesture is engaged — we missed the up. Synthesize it so nothing sticks.
        if isEngaged, !targetMaskPresent {
            return Result(input: .keyUp, consume: false, fnRawPresent: fnRawPresent, fnArmed: fnArmed)
        }
        return Result(input: nil, consume: false, fnRawPresent: fnRawPresent, fnArmed: fnArmed)
    }
}

// MARK: - Live monitor

@MainActor
final class HoldToTalkMonitor {
    static let shared = HoldToTalkMonitor()

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "HoldToTalk")

    /// Debounce before a held key starts recording — also the combo/blip window.
    private let armingDelay: TimeInterval = 0.15
    /// Window after a quick tap to catch a second tap (double-tap → latched record).
    private let doubleTapWindow: TimeInterval = 0.35
    /// Safety cap: force-stop if a release is ever lost so recording can't stick.
    private let maxHoldDuration: TimeInterval = 60

    /// Escape virtual keycode — cancels (discards) an active recording.
    private let escKeyCode: Int64 = 0x35

    /// The currently-armed key. `.off` ⇒ the tap is not running.
    private var targetKey: HoldToTalkKey = .off
    private var classifier = HoldToTalkClassifier()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Guards the async window in start() (the Accessibility await) so two rapid
    /// reconfigure() calls can't each create a tap and leak one.
    private var startInFlight = false

    private var armingWork: DispatchWorkItem?
    private var doubleTapWork: DispatchWorkItem?
    private var maxDurationWork: DispatchWorkItem?

    /// Raw physical Fn state + whether we armed a bare-Fn hold (Fn keycode is
    /// unreliable, so Fn is tracked by flag edge; only bare Fn is consumed/armed).
    private var fnRawPresent = false
    private var fnArmed = false

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
                // Pass-through returns the SAME borrowed event unretained — the tap
                // doesn't transfer ownership. passRetained would leak on every event,
                // and this tap sees every keystroke. nil only for a consumed event.
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let monitor = Unmanaged<HoldToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                // The source is on the main run loop, so the callback runs on main.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.handleTapDisabled() }
                    return Unmanaged.passUnretained(cgEvent)
                }
                let consume = MainActor.assumeIsolated { monitor.handle(type: type, event: cgEvent) }
                return consume ? nil : Unmanaged.passUnretained(cgEvent)
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
        fnRawPresent = false
        fnArmed = false
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
            // Esc cancels an active recording; everything else is a combo signal.
            let isEsc = event.getIntegerValueField(.keyboardEventKeycode) == escKeyCode
            process(classifier.handle(isEsc ? .escKeyDown : .otherKeyDown))
            return false

        case .flagsChanged:
            guard let mask = targetKey.flagMask else { return false }
            let flags = event.flags
            let otherModifiersPresent = flags.contains(.maskCommand) || flags.contains(.maskControl)
                || flags.contains(.maskAlternate) || flags.contains(.maskShift)
            let result = HoldToTalkDecoder.decodeFlagsChanged(
                targetKey: targetKey,
                keycodeMatchesTarget: targetKey.keyCode == event.getIntegerValueField(.keyboardEventKeycode),
                targetMaskPresent: flags.contains(mask),
                fnPresent: flags.contains(.maskSecondaryFn),
                otherModifiersPresent: otherModifiersPresent,
                fnRawPresent: fnRawPresent,
                fnArmed: fnArmed,
                isEngaged: classifier.isEngaged
            )
            fnRawPresent = result.fnRawPresent
            fnArmed = result.fnArmed
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
            case .scheduleDoubleTapWindow:
                scheduleDoubleTapWindow()
            case .cancelDoubleTapWindow:
                doubleTapWork?.cancel()
                doubleTapWork = nil
            case .beginRecording:
                beginRecording()
            case .scheduleMaxDuration:
                scheduleMaxDuration()
            case .requestStop:
                maxDurationWork?.cancel()
                maxDurationWork = nil
                Task { await VoiceCaptureViewModel.shared.requestStop() }
            case .cancelRecording:
                maxDurationWork?.cancel()
                maxDurationWork = nil
                VoiceCaptureViewModel.shared.cancel() // discard, no route
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

    private func scheduleDoubleTapWindow() {
        doubleTapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.doubleTapWork = nil
            self.process(self.classifier.handle(.doubleTapWindowFired))
        }
        doubleTapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
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
        doubleTapWork?.cancel()
        doubleTapWork = nil
        maxDurationWork?.cancel()
        maxDurationWork = nil
    }
}
