//
//  FluidAudioTranscriber.swift
//  Ghostwire
//
//  GW-229: on-device speech engine via FluidAudio (FluidInference) — the proper
//  replacement for the ~1-min-capped SFSpeechRecognizer path. Behind our
//  `Transcriber` protocol, with swappable models spanning BOTH of FluidAudio's
//  paths so we can A/B them:
//    • STREAMING (cache-aware, no length limit): Nemotron EN, Parakeet EOU.
//      Live `appendAudio` → partials → `finish()`.
//    • BATCH TDT (the classic Parakeet TDT v2/v3): we capture the recording to
//      a temp file and `transcribe(url)` on stop (handles resampling + long
//      audio via disk-backed processing). No live partials (fine — the record
//      UI is an ambient indicator, not a live transcript).
//
//  All on-device on the Apple Neural Engine; models auto-download from Hugging
//  Face once on first use (public, no token), then fully offline. Loaded
//  managers/models are cached so download + ANE compile happen once.
//

import AVFoundation
import FluidAudio
import Foundation
import os

/// Selectable speech model. Backs the Settings picker.
enum VoiceModel: String, CaseIterable, Sendable {
    case nemotronEN // streaming Nemotron 1120ms — recommended default (instant on stop)
    case parakeetV3 // batch Parakeet TDT v3 — multilingual (25 langs), cleanest formatting
    case parakeetV2 // batch Parakeet TDT v2 — English, "highest recall"

    var displayName: String {
        switch self {
        case .nemotronEN: return "Nemotron (English) — recommended"
        case .parakeetV3: return "Parakeet TDT v3 (multilingual)"
        case .parakeetV2: return "Parakeet TDT v2 (English)"
        }
    }

    /// Approximate on-disk download size, for the Settings UI.
    var approxDownload: String {
        switch self {
        case .nemotronEN: return "~600 MB"
        case .parakeetV3: return "~470 MB"
        case .parakeetV2: return "~450 MB"
        }
    }

    enum Kind {
        case streaming(StreamingModelVariant)
        case batchTDT(AsrModelVersion)
    }

    var kind: Kind {
        switch self {
        case .nemotronEN: return .streaming(.nemotron1120ms)
        case .parakeetV3: return .batchTDT(.v3)
        case .parakeetV2: return .batchTDT(.v2)
        }
    }
}

@MainActor
final class FluidAudioTranscriber: Transcriber {
    nonisolated static var engineName: String { "FluidAudio (on-device)" }
    nonisolated var privacy: TranscriptionPrivacy { .onDevice }

    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "VoiceCapture")

    // Loaded engines cached so download + ANE compile happen once.
    private static var streamingManagers: [String: any StreamingAsrManager] = [:]
    private static var batchManagers: [AsrModelVersion: AsrManager] = [:]
    // In-flight loads so concurrent callers (launch warm + first gesture + Settings
    // retry) coalesce onto ONE download/load instead of each starting their own.
    // Stored before the first await, and the static state is @MainActor-isolated, so
    // the check-then-store critical section is atomic.
    private static var streamingLoads: [String: Task<any StreamingAsrManager, Error>] = [:]
    private static var batchLoads: [AsrModelVersion: Task<AsrManager, Error>] = [:]

    private let model: VoiceModel
    private var streaming: (any StreamingAsrManager)?
    private var batch: AsrManager?
    private var consumer: Task<Void, Never>?
    private nonisolated(unsafe) var bufferStream: AsyncStream<AVAudioPCMBuffer>.Continuation?
    // Batch mode: capture to a temp file, transcribe on finish.
    private var captureFile: AVAudioFile?
    private var captureURL: URL?

    nonisolated init(model: VoiceModel) {
        self.model = model
    }

    // MARK: - Cached engine loaders

    private static func streamingManager(_ variant: StreamingModelVariant) async throws -> any StreamingAsrManager {
        if let cached = streamingManagers[variant.rawValue] { return cached }
        if let inflight = streamingLoads[variant.rawValue] { return try await inflight.value }
        let task = Task { () async throws -> any StreamingAsrManager in
            let mgr = variant.createManager()
            try await mgr.loadModels()
            return mgr
        }
        streamingLoads[variant.rawValue] = task
        do {
            let mgr = try await task.value
            streamingManagers[variant.rawValue] = mgr
            streamingLoads[variant.rawValue] = nil
            return mgr
        } catch {
            streamingLoads[variant.rawValue] = nil // let a later caller retry
            throw error
        }
    }

    private static func batchManager(_ version: AsrModelVersion) async throws -> AsrManager {
        if let cached = batchManagers[version] { return cached }
        if let inflight = batchLoads[version] { return try await inflight.value }
        let task = Task { () async throws -> AsrManager in
            let manager = AsrManager()
            let models = try await AsrModels.downloadAndLoad(version: version)
            try await manager.loadModels(models)
            return manager
        }
        batchLoads[version] = task
        do {
            let manager = try await task.value
            batchManagers[version] = manager
            batchLoads[version] = nil
            return manager
        } catch {
            batchLoads[version] = nil // let a later caller retry
            throw error
        }
    }

    /// Download (if needed) + load the model, updating `VoiceModelStore` so the
    /// UI can show progress. Throws if the load fails.
    static func ensureLoaded(_ model: VoiceModel) async throws {
        if isLoaded(model) { VoiceModelStore.shared.setReady(model); return }
        VoiceModelStore.shared.setDownloading(model)
        do {
            switch model.kind {
            case .streaming(let v): _ = try await streamingManager(v)
            case .batchTDT(let ver): _ = try await batchManager(ver)
            }
            VoiceModelStore.shared.setReady(model)
        } catch {
            VoiceModelStore.shared.setFailed(model)
            throw error
        }
    }

    /// Pre-download + load ahead of first use (best-effort). Used on launch for
    /// the default and when the user selects a model in Settings.
    static func prepare(_ model: VoiceModel) {
        Task { @MainActor in
            do { try await ensureLoaded(model) }
            catch { logger.error("FluidAudio prepare(\(model.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Loaded into memory this session (warm — no download or compile needed).
    static func isLoaded(_ model: VoiceModel) -> Bool {
        switch model.kind {
        case .streaming(let v): return streamingManagers[v.rawValue] != nil
        case .batchTDT(let ver): return batchManagers[ver] != nil
        }
    }

    // MARK: - Transcriber

    func start(onResult: @escaping @MainActor (TranscriptionResult) -> Void) async throws {
        // Download (if needed) + load, surfacing state to VoiceModelStore.
        do { try await Self.ensureLoaded(model) }
        catch {
            Self.logger.error("FluidAudio load failed (\(self.model.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw TranscriberError.engineFailure("model load failed")
        }
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferStream = continuation

        switch model.kind {
        case .streaming(let variant):
            // Already loaded by ensureLoaded above; this returns the cached manager.
            let mgr = try await Self.streamingManager(variant)
            try? await mgr.reset()
            self.streaming = mgr
            await mgr.setPartialTranscriptCallback { text in
                Task { @MainActor in onResult(TranscriptionResult(text: text, isFinal: false)) }
            }
            self.consumer = Task { [weak mgr] in
                for await buffer in stream {
                    guard let mgr else { break }
                    do {
                        try await mgr.appendAudio(buffer)
                        try await mgr.processBufferedAudio()
                    } catch {
                        // A failing chunk stays at the front of FluidAudio's
                        // buffer and would retry forever while audio piles up —
                        // stop feeding; finish() salvages the partial so far.
                        Self.logger.error("FluidAudio streaming chunk failed: \(error.localizedDescription, privacy: .public)")
                        break
                    }
                }
            }

        case .batchTDT(let version):
            // Already loaded by ensureLoaded above; this returns the cached manager.
            self.batch = try await Self.batchManager(version)
            // Capture the recording to a temp file; transcribe on finish.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostwire-voice-\(UUID().uuidString).caf")
            self.captureURL = url
            self.consumer = Task { [weak self] in
                for await buffer in stream {
                    guard let self else { break }
                    await self.writeCapture(buffer, to: url)
                }
            }
        }
    }

    /// Batch mode: append a buffer to the temp capture file (created lazily from
    /// the first buffer's format). Runs on the serial consumer task.
    private func writeCapture(_ buffer: AVAudioPCMBuffer, to url: URL) {
        do {
            if captureFile == nil {
                captureFile = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try captureFile?.write(from: buffer)
        } catch {
            Self.logger.error("voice capture-file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        bufferStream?.yield(buffer)
    }

    func finish() async -> String {
        bufferStream?.finish()
        await consumer?.value
        consumer = nil

        var text = ""
        switch model.kind {
        case .streaming:
            if let mgr = streaming {
                text = (try? await mgr.finish()) ?? ""
                // Salvage: if finish() failed/empty (e.g. a decode error stopped
                // the consumer), fall back to the partial accumulated so far.
                if text.isEmpty { text = await mgr.getPartialTranscript() }
            }
            streaming = nil
        case .batchTDT:
            captureFile = nil // close the file
            if let mgr = batch, let url = captureURL,
               var state = try? TdtDecoderState(decoderLayers: 2) {
                text = (try? await mgr.transcribe(url, decoderState: &state).text) ?? ""
            }
            batch = nil
            if let url = captureURL { try? FileManager.default.removeItem(at: url) }
            captureURL = nil
        }

        Self.logger.notice("FluidAudio transcript: \(text.count, privacy: .public) chars (\(self.model.rawValue, privacy: .public))")
        return text
    }

    func cancel() {
        bufferStream?.finish()
        consumer?.cancel()
        consumer = nil
        captureFile = nil
        if let url = captureURL { try? FileManager.default.removeItem(at: url) }
        captureURL = nil
        let mgr = streaming
        streaming = nil
        batch = nil
        Task { try? await mgr?.reset() }
    }
}
