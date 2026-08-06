//
//  VoiceCaptureViewModel.swift
//  Ghostwire
//
//  GW-229: the voice-capture state machine. Drives the ambient record indicator
//  and routes the finished transcript. Independent of the focused app:
//
//    hotkey → begin() (record; ambient red indicator in the CLOSED notch) →
//    stopRecording() → route:
//      • always: put the transcript on the clipboard + save it to the Shelf
//      • if "paste into focused field" is on AND an editable field is focused
//        → paste it there (true dictation; focused in an agent's input == send
//        to agent for free) and stay put
//      • otherwise → pop the Shelf open so the saved item is visible (send to
//        agent / copy / paste / keep — all via the Shelf's existing actions)
//
//  Every external dependency is an injected seam (transcriber, audio, clipboard,
//  shelf, focus probe, paste, reveal) so the whole routing is unit-tested with a
//  mock engine — no microphone, Accessibility, terminal, or disk. The toggle
//  flips begin()/stopRecording(), so a future push-to-talk trigger bolts on.
//

import Defaults
import Foundation
import os
import SwiftUI

@MainActor
final class VoiceCaptureViewModel: ObservableObject {
    static let shared = VoiceCaptureViewModel()

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "VoiceCapture")

    enum Stage: Equatable {
        /// Not active.
        case idle
        /// Recording; shown as the ambient indicator in the closed notch.
        case recording
    }

    // MARK: - Published state

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var partialText: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy: Bool = false
    /// True while a cold model is downloading/loading before recording starts —
    /// drives a "Preparing model…" surface instead of a silent wait.
    @Published private(set) var preparing: Bool = false

    // MARK: - Seams (injected; default to the real services)

    private let makeTranscriber: @MainActor () -> Transcriber
    private let audio: AudioCapturing
    private let saveToShelf: @MainActor (String) -> Void
    private let copyToClipboard: @MainActor (String) -> Void
    private let isFieldFocused: @MainActor () -> Bool
    private let pasteIntoField: @MainActor () async -> Bool
    private let pasteEnabled: @MainActor () -> Bool
    /// Whether the selected engine is already loaded (warm) — if not, begin()
    /// shows a "Preparing model…" surface while it downloads/loads.
    private let isEngineWarm: @MainActor () -> Bool

    /// Pop the notch open on the Shelf tab (where the saved transcript appears).
    var onRevealShelf: @MainActor () -> Void = {}
    /// Open / close the notch for an error message.
    var onRequestOpen: @MainActor () -> Void = {}
    var onRequestClose: @MainActor () -> Void = {}

    private var transcriber: Transcriber?

    /// Monotonic session token — bumped at begin() entry and on cancel() so any
    /// async tail (stopRecording finalizing, or begin's own start/prepare awaits)
    /// that resumes after a supersede can detect it's stale and drop the result.
    private var generation = 0

    /// GW-270: a stop (push-to-talk release) that lands while begin() is still
    /// preparing/starting can't stop yet — it sets this so begin()'s tail routes
    /// the moment recording is live. Cleared on every begin() entry and reset().
    private var stopWhenReady = false

    // MARK: - Init

    init(
        makeTranscriber: @escaping @MainActor () -> Transcriber = { DefaultTranscriberFactory.make() },
        audio: AudioCapturing = AudioCaptureService(),
        saveToShelf: @escaping @MainActor (String) -> Void = { text in
            ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: text))])
        },
        copyToClipboard: @escaping @MainActor (String) -> Void = { text in
            ClipboardHistoryService.shared.stagePlainTextForPaste(text)
        },
        isFieldFocused: @escaping @MainActor () -> Bool = { FocusedFieldService.isEditableFieldFocused() },
        pasteIntoField: @escaping @MainActor () async -> Bool = { await FocusedFieldService.paste() },
        pasteEnabled: @escaping @MainActor () -> Bool = { Defaults[.voicePasteIntoFocusedField] },
        isEngineWarm: @escaping @MainActor () -> Bool = {
            let selected = Defaults[.voiceModel]
            if selected == DefaultTranscriberFactory.appleEngineKey { return true }
            if let model = VoiceModel(rawValue: selected) { return FluidAudioTranscriber.isLoaded(model) }
            return true
        }
    ) {
        self.makeTranscriber = makeTranscriber
        self.audio = audio
        self.saveToShelf = saveToShelf
        self.copyToClipboard = copyToClipboard
        self.isFieldFocused = isFieldFocused
        self.pasteIntoField = pasteIntoField
        self.pasteEnabled = pasteEnabled
        self.isEngineWarm = isEngineWarm
    }

    // MARK: - Trigger

    /// Hotkey toggle: start recording when idle, stop when recording.
    func toggle() async {
        switch stage {
        case .idle: await begin()
        case .recording: await stopRecording()
        }
    }

    /// GW-270: push-to-talk release. Stop + route now if recording is live; if a
    /// release lands while begin() is still preparing/starting, defer it so begin's
    /// tail routes the moment recording exists. Strict no-op when there's no live or
    /// pending session, so a stray up-event can't strand a deferred stop.
    func requestStop() async {
        if stage == .recording, !isBusy {
            await stopRecording()
        } else if isBusy || preparing {
            stopWhenReady = true
        }
    }

    // MARK: - Recording

    func begin() async {
        guard stage == .idle, !isBusy else { return }
        // Retrying after an error that opened the notch: clear it and collapse
        // so recording starts cleanly in the CLOSED notch (ambient indicator).
        if errorMessage != nil {
            errorMessage = nil
            onRequestClose()
        }
        isBusy = true
        partialText = ""
        stopWhenReady = false
        // Mark this session live up front so a cancel()/release landing during the
        // start/prepare awaits below is detected as a supersede (gen mismatch) and
        // can't be clobbered into a stuck `.recording`.
        generation &+= 1
        let gen = generation

        // Cold engine (first use / model not downloaded): show a "Preparing…"
        // surface while start() downloads/loads, instead of a silent wait.
        let warm = isEngineWarm()
        if !warm {
            preparing = true
            onRequestOpen()
        }

        let engine = makeTranscriber()
        transcriber = engine

        do {
            try await engine.start(onResult: { [weak self] result in
                self?.partialText = result.text
            })
            // Canceled (or superseded) during the cold-model prepare: cancel() has
            // already torn down, and a newer begin() may now own `audio`/`isBusy`/
            // `transcriber`. Tear down ONLY this stale engine — touching the shared
            // audio or busy state here would kill the newer session. (This is the
            // only await in begin(); audio.start() below is synchronous, so no
            // second generation re-check is needed.)
            guard gen == generation else {
                engine.cancel()
                return
            }
            // Feed capture into the engine; the engine instance is captured
            // directly so the audio thread never touches main-isolated state.
            try audio.start(onBuffer: { [weak engine] buffer in
                engine?.append(buffer)
            })
            if preparing {
                preparing = false
                onRequestClose() // collapse the prep surface; recording is ambient
            }
            stage = .recording
        } catch let error as TranscriberError {
            transcriber = nil
            preparing = false
            stopWhenReady = false
            showError(Self.message(for: error))
        } catch {
            transcriber = nil
            preparing = false
            stopWhenReady = false
            showError("Couldn’t start recording.")
        }
        isBusy = false

        // A push-to-talk release that landed mid-prepare → route it now that
        // recording is live (no-op unless start actually reached `.recording`).
        if stage == .recording, stopWhenReady {
            stopWhenReady = false
            await stopRecording()
        }
    }

    /// Stop capture, finalize, and route the transcript. An empty transcript
    /// just resets — nothing to save, paste, or reveal.
    func stopRecording() async {
        guard stage == .recording, !isBusy else { return }
        isBusy = true
        let gen = generation

        audio.stop()
        let finalText = await transcriber?.finish() ?? partialText

        // If the user canceled (or a new session started) while finalizing,
        // abort silently — cancel() already tore down.
        guard gen == generation, stage == .recording else {
            isBusy = false
            return
        }
        transcriber = nil

        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Don't vanish silently — a brief, self-dismissing hint.
            reset()
            showTransientError("Didn’t catch anything — try again.")
            return
        }

        // Always: live clipboard + durable Shelf record.
        copyToClipboard(trimmed)
        saveToShelf(trimmed)

        // Paste into the focused field when enabled + available; else reveal the
        // Shelf so the capture is visible. Reveal as a fallback if paste fails.
        if pasteEnabled(), isFieldFocused() {
            let pasted = await pasteIntoField()
            Self.logger.notice("voice routed: paste (\(trimmed.count, privacy: .public) chars, ok=\(pasted, privacy: .public))")
            if !pasted { onRevealShelf() }
        } else {
            Self.logger.notice("voice routed: shelf+clipboard (\(trimmed.count, privacy: .public) chars)")
            onRevealShelf()
        }

        reset()
    }

    /// Dismiss without producing a transcript (esc, scrim, or error dismiss).
    func cancel() {
        generation &+= 1
        // Stop capture BEFORE tearing down the engine so no buffer can arrive
        // into a request we're ending/nilling (avoids the append/teardown race).
        audio.stop()
        transcriber?.cancel()
        transcriber = nil
        let hadError = errorMessage != nil
        reset()
        if hadError { onRequestClose() }
    }

    // MARK: - Internal

    private func showError(_ message: String) {
        errorMessage = message
        onRequestOpen()
    }

    /// A brief, self-dismissing message (e.g. "didn't catch anything") so a
    /// failed capture isn't a silent no-op.
    private func showTransientError(_ message: String) {
        errorMessage = message
        onRequestOpen()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, self.errorMessage == message else { return }
            self.errorMessage = nil
            self.onRequestClose()
        }
    }

    private func reset() {
        stage = .idle
        partialText = ""
        errorMessage = nil
        isBusy = false
        preparing = false
        stopWhenReady = false
    }

    private static func message(for error: TranscriberError) -> String {
        switch error {
        case .permissionDenied:
            return "Microphone & Speech Recognition access needed — enable them in System Settings ▸ Privacy."
        case .unavailable:
            return "On-device speech isn’t available for your language."
        case .engineFailure:
            return "Couldn’t load the speech model — try a different engine in Settings ▸ Voice."
        }
    }
}
