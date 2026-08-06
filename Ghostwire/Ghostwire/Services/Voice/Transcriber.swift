//
//  Transcriber.swift
//  Ghostwire
//
//  GW-229: speech → agent. The swappable speech-to-text seam.
//
//  A `Transcriber` turns a stream of captured audio buffers into a live
//  transcript. The protocol is deliberately engine-agnostic so the default
//  Apple engine can be swapped for Parakeet / WhisperKit / a BYO passthrough
//  later (GW-229 builds only the Apple default — the others bolt onto this
//  protocol without reworking the capture/VM/UI above it).
//
//  Default engine = Apple, OS-adaptive (see `DefaultTranscriberFactory`):
//    - macOS 26+   → SpeechAnalyzer / SpeechTranscriber  (compiler-gated seam)
//    - macOS 14–15 → SFSpeechRecognizer (on-device)       (the shipping path)
//  The app deployment floor stays macOS 14.0 — only the speech path branches.
//
//  PRIVACY: every built-in engine is on-device. We NEVER ship a cloud STT —
//  the SFSpeechRecognizer path forces `requiresOnDeviceRecognition` and refuses
//  rather than fall back to the server. Audio never leaves the machine.
//

import AVFoundation
import Defaults
import Foundation
import OSLog
import Speech

/// One transcription update from a `Transcriber`. `text` is the best-so-far
/// string (a partial hypothesis until `isFinal` is true).
struct TranscriptionResult: Equatable, Sendable {
    var text: String
    var isFinal: Bool
}

/// Why a transcription couldn't run — drives the in-notch error copy.
enum TranscriberError: Error, Equatable {
    /// Microphone and/or speech-recognition authorization was denied.
    case permissionDenied
    /// No on-device recognizer for the locale, or the engine isn't available.
    /// (We refuse rather than silently use a cloud recognizer.)
    case unavailable
    /// The engine reported a runtime failure.
    case engineFailure(String)
}

/// Where the audio is transcribed — surfaced as a tag in the record UI so the
/// local-first guarantee is legible. Built-in engines are always `.onDevice`;
/// a future BYO passthrough would be `.external` (NCC only ever receives the
/// already-transcribed text; the tool's own privacy applies).
enum TranscriptionPrivacy: Equatable, Sendable {
    case onDevice
    case external(toolName: String)

    /// Short label for the record UI ("On-device" / "Uses Whisper Flow").
    var label: String {
        switch self {
        case .onDevice: return "On-device"
        case .external(let tool): return "Uses \(tool)"
        }
    }
}

/// The swappable speech-to-text engine seam.
///
/// Lifecycle: `start(onResult:)` opens a streaming session; the caller feeds
/// captured audio with `append(_:)`; partial + final hypotheses arrive on
/// `onResult`; `finish()` flushes and returns the final transcript; `cancel()`
/// tears down without producing one. Implementations are class-bound (the VM
/// holds and drives one live instance).
protocol Transcriber: AnyObject {
    /// Human-facing engine name (Settings / debug).
    static var engineName: String { get }

    /// On-device vs external — drives the privacy tag.
    var privacy: TranscriptionPrivacy { get }

    /// Begin a streaming session. Throws `TranscriberError` if permission is
    /// denied or no on-device engine is available. `onResult` is delivered on
    /// the main actor.
    func start(onResult: @escaping @MainActor (TranscriptionResult) -> Void) async throws

    /// Feed one captured audio buffer into the running session.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Stop capturing, flush, and return the final transcript text.
    func finish() async -> String

    /// Abort the session without producing a final transcript.
    func cancel()
}

// MARK: - Permissions

/// Microphone + speech-recognition authorization, requested at first use.
enum VoicePermissions {
    /// Request (or confirm) speech-recognition authorization.
    static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    /// Request (or confirm) microphone access.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// Both gates, requested in turn. `false` if either is denied.
    static func requestAll() async -> Bool {
        let mic = await requestMicrophoneAccess()
        guard mic else { return false }
        return await requestSpeechAuthorization()
    }
}

// MARK: - Default engine selection (OS-adaptive)

/// Builds the default Apple transcriber for the running OS.
///
/// The macOS 26 `SpeechAnalyzer` path is compiler-gated: its symbols don't
/// exist in SDKs older than 26, and `#available` is a *runtime* gate that still
/// requires the types at compile time. `#if compiler(>=6.2)` (the toolchain
/// that ships the macOS 26 SDK) keeps that branch dormant on older Xcodes so
/// the app still builds on the macOS 14 floor — there, the on-device
/// `SFSpeechRecognizer` path is selected for every supported OS.
enum DefaultTranscriberFactory {
    /// Sentinel stored in `Defaults[.voiceModel]` to select Apple's built-in
    /// engine (SpeechAnalyzer on macOS 26, else SFSpeechRecognizer) instead of a
    /// FluidAudio model.
    static let appleEngineKey = "apple"

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "VoiceCapture")

    static func make(locale: Locale = .current) -> Transcriber {
        let selected = Defaults[.voiceModel]
        if selected == appleEngineKey {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                // Which engine backs "apple" depends on the BUILD toolchain, not
                // just the setting — a Swift 6.2+ toolchain compiles this branch
                // in and silently swaps SFSpeechRecognizer for SpeechAnalyzer on
                // macOS 26 (GW-352). Log it, or the swap is invisible.
                logger.notice("transcriber selected: SpeechAnalyzer (apple, macOS 26+)")
                return SpeechAnalyzerTranscriber(locale: locale)
            }
            #endif
            logger.notice("transcriber selected: AppleSpeech/SFSpeechRecognizer (apple)")
            return AppleSpeechTranscriber(locale: locale)
        }
        // Default: on-device long-form FluidAudio engine (no ~1-min limit).
        let model = VoiceModel(rawValue: selected) ?? .nemotronEN
        logger.notice("transcriber selected: FluidAudio (\(model.rawValue, privacy: .public))")
        return FluidAudioTranscriber(model: model)
    }
}
