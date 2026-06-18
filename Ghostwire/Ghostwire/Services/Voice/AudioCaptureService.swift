//
//  AudioCaptureService.swift
//  Ghostwire
//
//  GW-229: microphone capture for voice → agent. Taps the default input node
//  with `AVAudioEngine` and forwards each PCM buffer to the active
//  `Transcriber`. Capture stays local — buffers go straight to the on-device
//  engine and are never written or sent anywhere.
//

import AVFoundation
import Foundation
import os

/// The capture seam the view-model drives. A protocol so tests run the voice
/// flow without a live microphone.
protocol AudioCapturing: AnyObject {
    /// Start capturing; `onBuffer` is called for each captured PCM buffer
    /// (on the audio render thread). Throws if the engine can't start.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// Stop capturing and remove the tap.
    func stop()
}

final class AudioCaptureService: AudioCapturing {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private static let logger = Logger(subsystem: "com.ghostwire.notch", category: "VoiceCapture")

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero sample-rate format means no usable input device.
        guard format.sampleRate > 0 else {
            throw TranscriberError.unavailable
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Self.logger.error("AVAudioEngine failed to start: \(error.localizedDescription)")
            throw TranscriberError.engineFailure(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
