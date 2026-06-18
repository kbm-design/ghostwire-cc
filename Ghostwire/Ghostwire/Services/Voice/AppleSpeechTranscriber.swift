//
//  AppleSpeechTranscriber.swift
//  Ghostwire
//
//  GW-229: the zero-download backup speech engine — Apple's on-device
//  `SFSpeechRecognizer` (the default engine is FluidAudio; this is what the
//  "Apple built-in" picker option uses, and the fallback when no model is
//  downloaded). Works on the macOS 14.0 floor (the macOS 26 `SpeechAnalyzer`
//  engine is a compiler-gated seam, see `SpeechAnalyzerTranscriber`).
//
//  LONG DICTATION: on-device `SFSpeechRecognizer` does NOT cap with an error —
//  it SILENTLY FORGETS earlier audio after ~1 min, so its `formattedString`
//  shrinks to a recent window. So we can't wait for a final/error that never
//  comes — instead we PROACTIVELY roll over on a timer (`rolloverInterval`,
//  under the forget threshold): commit the current partial to `finalizedText`
//  and start a fresh request that keeps consuming the audio tap. `finish()`
//  returns the accumulated text. A real final/error also commits + restarts.
//
//  PRIVACY: `requiresOnDeviceRecognition` is forced on and we REFUSE
//  (`.unavailable`) when there's no on-device model — never the server.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class AppleSpeechTranscriber: Transcriber {
    nonisolated static var engineName: String { "Apple Speech (on-device)" }
    nonisolated var privacy: TranscriptionPrivacy { .onDevice }

    /// Roll the recognition request over before the on-device recognizer starts
    /// forgetting earlier audio (~1 min). Kept comfortably under that.
    private static let rolloverInterval: Duration = .seconds(40)

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    // `append(_:)` runs on the audio render thread while MainActor code starts/
    // restarts/ends the request. The shared optional goes through `requestLock`;
    // the VM also stops the audio tap before any teardown.
    private let requestLock = NSLock()
    private nonisolated(unsafe) var _bufferRequest: SFSpeechAudioBufferRecognitionRequest?

    private nonisolated func currentRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        requestLock.lock(); defer { requestLock.unlock() }
        return _bufferRequest
    }
    private nonisolated func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requestLock.lock(); defer { requestLock.unlock() }
        _bufferRequest = request
    }

    /// Committed text from finalized segments (across request restarts).
    private var finalizedText = ""
    /// The in-flight request's latest partial hypothesis.
    private var currentPartial = ""
    /// Monotonic token for the active recognition request. Terminal callbacks
    /// from a capped request can arrive after the replacement request starts.
    private var activeRequestID = 0
    /// The request just rolled over — we still accept ITS final/error callback
    /// (which carries the segment's complete tail) so a rollover never drops the
    /// speech captured between the last partial and the boundary.
    private var pendingFinalRequestID: Int?
    /// True once `finish()` has been requested — the next final/error resolves.
    private var finishing = false
    private var finishResolved = false
    private var finishContinuation: CheckedContinuation<String, Never>?
    private var onResult: (@MainActor (TranscriptionResult) -> Void)?

    private var combinedText: String {
        finalizedText.isEmpty ? currentPartial
            : (currentPartial.isEmpty ? finalizedText : finalizedText + " " + currentPartial)
    }

    nonisolated init(locale: Locale = .current) {
        self.locale = locale
    }

    func start(onResult: @escaping @MainActor (TranscriptionResult) -> Void) async throws {
        guard await VoicePermissions.requestAll() else {
            throw TranscriberError.permissionDenied
        }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriberError.unavailable
        }

        self.recognizer = recognizer
        self.onResult = onResult
        finalizedText = ""
        currentPartial = ""
        activeRequestID = 0
        pendingFinalRequestID = nil
        finishing = false
        finishResolved = false

        startRequest()
    }

    /// Open a fresh recognition request feeding off the (continuing) audio tap.
    private func startRequest() {
        guard let recognizer, !finishResolved else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        activeRequestID &+= 1
        let requestID = activeRequestID
        setRequest(req)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errCode: Int? = error.map { ($0 as NSError).code }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.handle(requestID: requestID, text: text, isFinal: isFinal, errorCode: errCode)
                }
            }
        }

        // The recognizer won't tell us when it's about to forget — roll over
        // ourselves before that, so long dictation is captured in stitched
        // segments rather than collapsing to the last sentence.
        Task { [weak self] in
            try? await Task.sleep(for: Self.rolloverInterval)
            self?.rolloverIfActive(requestID: requestID)
        }
    }

    /// Proactive rollover: commit the in-flight partial and start a fresh
    /// request so the recognizer's forgetting can't drop earlier speech. No-op
    /// if this request was already superseded (real final/error) or we're done.
    private func rolloverIfActive(requestID: Int) {
        guard requestID == activeRequestID, !finishing, !finishResolved else { return }
        // Don't commit the partial yet — end this request and let its FINAL
        // callback commit the complete segment (incl. the tail after the last
        // partial). Start the replacement now so new audio keeps being captured.
        pendingFinalRequestID = requestID
        currentPartial = ""
        currentRequest()?.endAudio()
        task = nil
        startRequest()
    }

    private func handle(requestID: Int, text: String?, isFinal: Bool, errorCode: Int?) {
        let terminal = isFinal || errorCode != nil

        if requestID == activeRequestID {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentPartial = text
            }
            onResult?(TranscriptionResult(text: combinedText, isFinal: false))
            guard terminal else { return }
            commitText(currentPartial)
            currentPartial = ""
            if finishing { resolveFinish() } else { task = nil; startRequest() }
            return
        }

        // The just-rolled-over request's final — commit its full segment tail.
        if requestID == pendingFinalRequestID, terminal {
            pendingFinalRequestID = nil
            commitText(text ?? "")
        }
        // Otherwise a truly stale callback — ignore.
    }

    private func commitText(_ text: String) {
        let seg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seg.isEmpty else { return }
        finalizedText = finalizedText.isEmpty ? seg : finalizedText + " " + seg
    }

    private func commitCurrentSegment() {
        commitText(currentPartial)
        currentPartial = ""
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        currentRequest()?.append(buffer)
    }

    func finish() async -> String {
        finishing = true
        if finishResolved { return finalizedText }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            finishContinuation = cont
            if let req = currentRequest() {
                req.endAudio()
            } else {
                // No active request (mid-restart gap) — settle with what we have.
                resolveFinish()
            }
            // Safety net: if no final/error arrives, settle after a moment so
            // the caller never hangs.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.resolveFinish()
            }
        }
    }

    func cancel() {
        finishing = true
        task?.cancel()
        currentRequest()?.endAudio()
        resolveFinish()
    }

    /// Settle once: commit any in-flight partial, resume `finish()`, drop handles.
    private func resolveFinish() {
        guard !finishResolved else { return }
        finishResolved = true
        commitCurrentSegment()
        let text = finalizedText
        task = nil
        setRequest(nil)
        let cont = finishContinuation
        finishContinuation = nil
        cont?.resume(returning: text)
    }
}
