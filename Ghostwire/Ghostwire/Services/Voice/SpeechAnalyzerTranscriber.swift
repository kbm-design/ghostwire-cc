//
//  SpeechAnalyzerTranscriber.swift
//  Ghostwire
//
//  GW-229: the macOS 26+ speech engine — Apple's `SpeechAnalyzer` /
//  `SpeechTranscriber` (the good on-device long-form model: cleaner output,
//  auto language detection, ANE-accelerated, free).
//
//  ⚠️ COMPILE-GATED SEAM. `SpeechAnalyzer`/`SpeechTranscriber` ship in the
//  macOS 26 SDK only. `#available(macOS 26)` is a *runtime* gate — the symbols
//  must still exist at *compile* time — so this whole file is wrapped in
//  `#if compiler(>=6.2)` (the Swift toolchain that ships the macOS 26 SDK,
//  Xcode 26). On older Xcodes the file is excluded entirely and
//  `DefaultTranscriberFactory` selects `AppleSpeechTranscriber` instead, so the
//  app still builds on the macOS 14.0 floor. This path is wired but NOT
//  compile-tested on the current toolchain (Xcode 16.4 / SDK 15.5) — live-
//  verify it when building with Xcode 26.
//

#if compiler(>=6.2)

import AVFoundation
import Foundation
import Speech

@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerTranscriber: Transcriber {
    nonisolated static var engineName: String { "Apple SpeechAnalyzer (on-device)" }
    nonisolated var privacy: TranscriptionPrivacy { .onDevice }

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?

    // Append-path state read from the audio tap thread (yield is thread-safe).
    private nonisolated(unsafe) var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private nonisolated(unsafe) var analyzerFormat: AVAudioFormat?

    // Transcript accumulates finalized segments; the volatile hypothesis is the
    // tail shown live until it's finalized.
    private var finalizedText = ""
    private var volatileText = ""
    private var finishResolved = false
    private var finishContinuation: CheckedContinuation<String, Never>?
    private var onResult: (@MainActor (TranscriptionResult) -> Void)?

    nonisolated init(locale: Locale = .current) {
        self.locale = locale
    }

    func start(onResult: @escaping @MainActor (TranscriptionResult) -> Void) async throws {
        guard await VoicePermissions.requestAll() else {
            throw TranscriberError.permissionDenied
        }

        self.onResult = onResult
        self.finalizedText = ""
        self.volatileText = ""
        self.finishResolved = false

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Ensure the on-device model for this locale is installed — no cloud.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        self.transcriber = transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = continuation

        self.resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await self.handle(text: text, isFinal: isFinal)
                }
            } catch {
                // Stream ended on error — settle with what we have.
            }
            await self.settleFinish()
        }

        try await analyzer.start(inputSequence: stream)
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder else { return }
        let prepared = Self.convert(buffer, to: analyzerFormat)
        inputBuilder.yield(AnalyzerInput(buffer: prepared))
    }

    func finish() async -> String {
        if finishResolved { return finalizedText + volatileText }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            finishContinuation = cont
            inputBuilder?.finish()
            Task { [weak self] in
                guard let self else { return }
                try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
        }
    }

    func cancel() {
        inputBuilder?.finish()
        resultsTask?.cancel()
        Task { [weak self] in await self?.analyzer?.cancelAndFinishNow() }
        settleFinish()
    }

    // MARK: - Internal

    private func handle(text: String, isFinal: Bool) {
        if isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        onResult?(TranscriptionResult(text: finalizedText + volatileText, isFinal: false))
    }

    private func settleFinish() {
        guard !finishResolved else { return }
        finishResolved = true
        let text = finalizedText + volatileText
        let cont = finishContinuation
        finishContinuation = nil
        inputBuilder = nil
        cont?.resume(returning: text)
    }

    /// Convert a captured buffer to the analyzer's preferred format when they
    /// differ; otherwise pass it through. Best-effort — on failure the original
    /// buffer is yielded.
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat?) -> AVAudioPCMBuffer {
        guard let target, target != buffer.format,
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(target.sampleRate * 0.4)
              )
        else { return buffer }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : buffer
    }
}

#endif
