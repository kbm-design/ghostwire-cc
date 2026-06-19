//
//  VoiceCaptureTests.swift
//  GhostwireTests
//
//  GW-229: voice capture → focus-aware routing. Exercises the whole flow
//  against a mock transcriber + mock audio + stubbed focus/paste/clipboard/
//  shelf seams (no microphone, Accessibility, terminal, or disk):
//    - record → stop routes the transcript
//    - focused field + paste enabled → pastes there; NOT revealed in the Shelf
//    - no field (or paste disabled) → clipboard + Shelf + Shelf revealed
//    - transcript ALWAYS lands on the clipboard + Shelf
//    - empty / cancel / cancel-during-finalize / permission-error edge cases
//

import AVFoundation
import XCTest
@testable import Ghostwire

@MainActor
final class VoiceCaptureTests: XCTestCase {

    // MARK: - Mocks

    private final class MockTranscriber: Transcriber, @unchecked Sendable {
        nonisolated static var engineName: String { "Mock" }
        nonisolated var privacy: TranscriptionPrivacy { .onDevice }

        var onResult: (@MainActor (TranscriptionResult) -> Void)?
        var started = false
        var appended = 0
        var cancelled = false
        var finishText = ""
        var startError: TranscriberError?

        var manualFinish = false
        private var finishCont: CheckedContinuation<String, Never>?

        /// GW-270: gate start() so begin() can be suspended mid-prepare and a
        /// release/cancel injected during the await (the release-during-prepare race).
        var manualStart = false
        private var startCont: CheckedContinuation<Void, Error>?

        func start(onResult: @escaping @MainActor (TranscriptionResult) -> Void) async throws {
            if let startError { throw startError }
            self.onResult = onResult
            if manualStart { try await withCheckedThrowingContinuation { startCont = $0 } }
            started = true
        }
        func append(_ buffer: AVAudioPCMBuffer) { appended += 1 }
        func finish() async -> String {
            if manualFinish { return await withCheckedContinuation { finishCont = $0 } }
            return finishText
        }
        func cancel() { cancelled = true }

        @MainActor func emit(_ text: String, isFinal: Bool = false) {
            onResult?(TranscriptionResult(text: text, isFinal: isFinal))
        }
        @MainActor func completeFinish(_ text: String) {
            finishCont?.resume(returning: text); finishCont = nil
        }
        @MainActor func completeStart() { startCont?.resume(); startCont = nil }
        @MainActor func failStart(_ error: TranscriberError) {
            startCont?.resume(throwing: error); startCont = nil
        }
    }

    private final class MockAudio: AudioCapturing, @unchecked Sendable {
        var started = false
        var stopped = false
        var startError: Error?
        func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
            if let startError { throw startError }
            started = true
            stopped = false // a fresh session is live; detect a later stray stop()
        }
        func stop() { stopped = true }
    }

    /// Records where the transcript went.
    private final class Sink {
        var clipboard: [String] = []
        var shelf: [String] = []
        var pasteCalls = 0
        var revealed = 0
        var opened = 0
        var closed = 0
    }

    // MARK: - Builder

    private func makeVM(
        transcriber: MockTranscriber,
        audio: MockAudio = MockAudio(),
        sink: Sink,
        fieldFocused: Bool,
        pasteEnabled: Bool = true,
        pasteSucceeds: Bool = true,
        engineWarm: Bool = true
    ) -> VoiceCaptureViewModel {
        let vm = VoiceCaptureViewModel(
            makeTranscriber: { transcriber },
            audio: audio,
            saveToShelf: { sink.shelf.append($0) },
            copyToClipboard: { sink.clipboard.append($0) },
            isFieldFocused: { fieldFocused },
            pasteIntoField: { sink.pasteCalls += 1; return pasteSucceeds },
            pasteEnabled: { pasteEnabled },
            isEngineWarm: { engineWarm }
        )
        vm.onRevealShelf = { sink.revealed += 1 }
        vm.onRequestOpen = { sink.opened += 1 }
        vm.onRequestClose = { sink.closed += 1 }
        return vm
    }

    // MARK: - Routing

    func testFocusedFieldPastesAndDoesNotRevealShelf() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: true)

        await vm.begin()
        XCTAssertEqual(vm.stage, .recording)
        t.finishText = "type this into the box"
        await vm.stopRecording()

        XCTAssertEqual(sink.clipboard, ["type this into the box"]) // always clipboard
        XCTAssertEqual(sink.shelf, ["type this into the box"])     // always Shelf
        XCTAssertEqual(sink.pasteCalls, 1)                          // pasted into field
        XCTAssertEqual(sink.revealed, 0)                            // not popped open
        XCTAssertEqual(vm.stage, .idle)
    }

    func testNoFocusedFieldCopiesSavesAndRevealsShelf() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()
        t.finishText = "a note for later"
        await vm.stopRecording()

        XCTAssertEqual(sink.clipboard, ["a note for later"])
        XCTAssertEqual(sink.shelf, ["a note for later"])
        XCTAssertEqual(sink.pasteCalls, 0)   // no field -> no paste
        XCTAssertEqual(sink.revealed, 1)     // Shelf popped open
        XCTAssertEqual(vm.stage, .idle)
    }

    func testPasteDisabledAlwaysRevealsEvenWithFocusedField() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: true, pasteEnabled: false)

        await vm.begin()
        t.finishText = "always to shelf"
        await vm.stopRecording()

        XCTAssertEqual(sink.pasteCalls, 0)
        XCTAssertEqual(sink.revealed, 1)
        XCTAssertEqual(sink.clipboard, ["always to shelf"])
        XCTAssertEqual(sink.shelf, ["always to shelf"])
    }

    func testPasteFailureFallsBackToRevealShelf() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: true, pasteSucceeds: false)

        await vm.begin()
        t.finishText = "couldn't paste"
        await vm.stopRecording()

        XCTAssertEqual(sink.pasteCalls, 1) // attempted
        XCTAssertEqual(sink.revealed, 1)   // fell back to reveal
    }

    func testEmptyTranscriptRoutesNothing() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: true)

        await vm.begin()
        t.finishText = "   \n "
        await vm.stopRecording()

        XCTAssertEqual(vm.stage, .idle)
        XCTAssertTrue(sink.clipboard.isEmpty)
        XCTAssertTrue(sink.shelf.isEmpty)
        XCTAssertEqual(sink.pasteCalls, 0)
        XCTAssertEqual(sink.revealed, 0)
    }

    // MARK: - Recording lifecycle

    func testPartialUpdatesDuringRecording() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()
        t.emit("hello")
        XCTAssertEqual(vm.partialText, "hello")
        t.finishText = "hello world"
        await vm.stopRecording()
        XCTAssertEqual(sink.shelf, ["hello world"])
    }

    func testCancelDuringRecordingTearsDownAndRoutesNothing() async {
        let t = MockTranscriber()
        let audio = MockAudio()
        let sink = Sink()
        let vm = makeVM(transcriber: t, audio: audio, sink: sink, fieldFocused: false)

        await vm.begin()
        vm.cancel()

        XCTAssertTrue(t.cancelled)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(vm.stage, .idle)
        XCTAssertTrue(sink.clipboard.isEmpty)
        XCTAssertTrue(sink.shelf.isEmpty)
        XCTAssertEqual(sink.revealed, 0)
    }

    func testCancelWhileStopIsAwaitingFinishDropsResult() async {
        let t = MockTranscriber()
        t.manualFinish = true
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()
        let stopTask = Task { await vm.stopRecording() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.cancel()
        t.completeFinish("a canceled transcript")
        await stopTask.value

        XCTAssertEqual(vm.stage, .idle)
        XCTAssertTrue(sink.clipboard.isEmpty)
        XCTAssertTrue(sink.shelf.isEmpty)
        XCTAssertEqual(sink.revealed, 0)
    }

    func testPermissionDeniedSurfacesErrorAndStaysIdle() async {
        let t = MockTranscriber()
        t.startError = .permissionDenied
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()

        XCTAssertEqual(vm.stage, .idle)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(sink.opened, 1) // opened the notch to show the error
    }

    func testRetryAfterErrorClearsErrorAndRecordsClosed() async {
        let failing = MockTranscriber()
        failing.startError = .permissionDenied
        let good = MockTranscriber()
        var calls = 0
        let sink = Sink()
        let vm = VoiceCaptureViewModel(
            makeTranscriber: { calls += 1; return calls == 1 ? failing : good },
            audio: MockAudio(),
            saveToShelf: { sink.shelf.append($0) },
            copyToClipboard: { sink.clipboard.append($0) },
            isFieldFocused: { false },
            pasteIntoField: { sink.pasteCalls += 1; return true },
            pasteEnabled: { true },
            // Deterministic warm engine: otherwise this reads real Defaults +
            // FluidAudio load state and the open/close counts go cold-path flaky.
            isEngineWarm: { true }
        )
        vm.onRevealShelf = { sink.revealed += 1 }
        vm.onRequestOpen = { sink.opened += 1 }
        vm.onRequestClose = { sink.closed += 1 }

        await vm.begin()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(sink.opened, 1)

        await vm.begin() // retry
        XCTAssertEqual(vm.stage, .recording)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(sink.closed, 1) // collapsed the error notch before recording

        vm.cancel()
    }

    // MARK: - GW-270 push-to-talk: requestStop() + release-during-prepare race

    /// A release that lands while begin() is still preparing defers the stop, and
    /// begin()'s tail routes the moment recording is live.
    func testRequestStopWhilePreparingRoutesWhenReady() async {
        let t = MockTranscriber()
        t.manualStart = true
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false, engineWarm: false)

        let beginTask = Task { await vm.begin() }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(vm.preparing)            // cold engine → preparing surface
        XCTAssertEqual(vm.stage, .idle)

        await vm.requestStop()                 // release during prepare → deferred
        t.finishText = "deferred capture"
        t.completeStart()                      // start resolves; recording goes live
        await beginTask.value

        XCTAssertEqual(vm.stage, .idle)        // routed + reset
        XCTAssertEqual(sink.shelf, ["deferred capture"])
        XCTAssertEqual(sink.clipboard, ["deferred capture"])
        XCTAssertEqual(sink.revealed, 1)
    }

    /// The bug this hardening fixes: a cancel() during the cold-model await must not
    /// be clobbered into a stuck `.recording`, and the VM must be usable afterward.
    func testCancelDuringPrepareDoesNotStrandRecording() async {
        let t = MockTranscriber()
        t.manualStart = true
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false, engineWarm: false)

        let beginTask = Task { await vm.begin() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.cancel()                            // lands mid-prepare
        t.completeStart()                      // start resolves AFTER the cancel
        await beginTask.value

        XCTAssertEqual(vm.stage, .idle)        // NOT stuck in .recording
        XCTAssertTrue(t.cancelled)
        XCTAssertTrue(sink.shelf.isEmpty)
        XCTAssertEqual(sink.revealed, 0)

        // Proves isBusy/preparing/stopWhenReady were all cleared: a fresh begin works.
        t.manualStart = false
        await vm.begin()
        XCTAssertEqual(vm.stage, .recording)
        vm.cancel()
    }

    /// P1: if start() throws after a release was deferred, the stale stopWhenReady
    /// must be cleared so the NEXT recording isn't phantom-stopped.
    func testStartErrorClearsDeferredStop() async {
        let t = MockTranscriber()
        t.manualStart = true
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false, engineWarm: false)

        let beginTask = Task { await vm.begin() }
        try? await Task.sleep(for: .milliseconds(20))
        await vm.requestStop()                 // deferred
        t.failStart(.engineFailure("boom"))    // start throws
        await beginTask.value

        XCTAssertEqual(vm.stage, .idle)
        XCTAssertNotNil(vm.errorMessage)

        // A fresh, warm recording must NOT auto-stop from the stale deferred flag.
        t.manualStart = false
        t.startError = nil
        await vm.begin()
        XCTAssertEqual(vm.stage, .recording)
        t.finishText = "fresh"
        await vm.stopRecording()
        XCTAssertEqual(sink.shelf, ["fresh"])
    }

    /// A stale cold-start that resumes AFTER a cancel + a newer begin must tear down
    /// only its own engine — never the shared audio/busy state of the newer session.
    func testStaleBeginDoesNotStopNewerRecording() async {
        let engineA = MockTranscriber(); engineA.manualStart = true
        let engineB = MockTranscriber()
        var calls = 0
        let audio = MockAudio()
        let sink = Sink()
        let vm = VoiceCaptureViewModel(
            makeTranscriber: { calls += 1; return calls == 1 ? engineA : engineB },
            audio: audio,
            saveToShelf: { sink.shelf.append($0) },
            copyToClipboard: { sink.clipboard.append($0) },
            isFieldFocused: { false },
            pasteIntoField: { sink.pasteCalls += 1; return true },
            pasteEnabled: { true },
            isEngineWarm: { false }
        )
        vm.onRevealShelf = { sink.revealed += 1 }
        vm.onRequestOpen = { sink.opened += 1 }
        vm.onRequestClose = { sink.closed += 1 }

        let beginA = Task { await vm.begin() }     // suspends in engineA.start
        try? await Task.sleep(for: .milliseconds(20))
        vm.cancel()                                 // A is now stale
        await vm.begin()                            // begin B starts fresh + records
        XCTAssertEqual(vm.stage, .recording)
        XCTAssertTrue(audio.started)

        engineA.completeStart()                     // A resumes stale
        await beginA.value

        XCTAssertEqual(vm.stage, .recording)        // B still live
        XCTAssertFalse(audio.stopped)               // A did NOT stop B's capture
        XCTAssertTrue(engineA.cancelled)            // A tore down its own engine
        XCTAssertFalse(engineB.cancelled)           // B untouched

        engineB.finishText = "the real one"
        await vm.stopRecording()
        XCTAssertEqual(sink.shelf, ["the real one"])
    }

    /// requestStop() with no live or pending session is a strict no-op (a stray
    /// up-event can't strand a deferred stop).
    func testRequestStopWhenIdleIsNoOp() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.requestStop()
        XCTAssertEqual(vm.stage, .idle)
        XCTAssertTrue(sink.shelf.isEmpty)

        // No lingering stopWhenReady: a normal record/stop still works.
        await vm.begin()
        XCTAssertEqual(vm.stage, .recording)
        t.finishText = "after no-op"
        await vm.stopRecording()
        XCTAssertEqual(sink.shelf, ["after no-op"])
    }

    /// Warm path: release while recording stops + routes exactly once.
    func testRequestStopWhileRecordingRoutesOnce() async {
        let t = MockTranscriber()
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()
        XCTAssertEqual(vm.stage, .recording)
        t.finishText = "held and released"
        await vm.requestStop()

        XCTAssertEqual(vm.stage, .idle)
        XCTAssertEqual(sink.shelf, ["held and released"])
        XCTAssertEqual(sink.clipboard, ["held and released"])
    }

    /// A second stop arriving while the first is finalizing must not double-route
    /// (e.g. a duplicated up-event or the recovery path firing).
    func testSecondStopWhileFinalizingRoutesOnce() async {
        let t = MockTranscriber()
        t.manualFinish = true
        let sink = Sink()
        let vm = makeVM(transcriber: t, sink: sink, fieldFocused: false)

        await vm.begin()
        let stopTask = Task { await vm.stopRecording() }
        try? await Task.sleep(for: .milliseconds(20))
        await vm.requestStop()                 // arrives mid-finalize → harmless
        t.completeFinish("only once")
        await stopTask.value

        XCTAssertEqual(sink.shelf, ["only once"])
        XCTAssertEqual(sink.clipboard, ["only once"])
        XCTAssertEqual(vm.stage, .idle)
    }
}
