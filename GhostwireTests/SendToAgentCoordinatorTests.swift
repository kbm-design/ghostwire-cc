//
//  SendToAgentCoordinatorTests.swift
//  GhostwireTests
//
//  GW-163: send-to-agent routing. The coordinator's job is the action→service
//  mapping and the picker handshake — target resolution itself is covered by
//  AgentTargetSelectionTests. Here we inject a recording double for the
//  injection service and a fixed session list, then assert:
//    - text payload  -> inject(text:)
//    - file payload  -> inject(file:)
//    - single/focused agent injects immediately (.delivered)
//    - several with none focused raises the picker (.awaitingPick), and the
//      pick resolves the held payload into the chosen session
//    - no live agent fails quietly (.failed)
//

import XCTest
@testable import Ghostwire

@MainActor
final class SendToAgentCoordinatorTests: XCTestCase {

    // MARK: - Recording double

    private final class RecordingInjector: AgentInjecting, @unchecked Sendable {
        enum Call: Equatable {
            case text(String, sessionId: String)
            case file(URL, sessionId: String)
        }
        var calls: [Call] = []
        var result: Result<Void, AgentInjectionService.InjectionError> = .success(())

        func inject(text: String, into session: SessionState, submit: Bool) async -> Result<Void, AgentInjectionService.InjectionError> {
            calls.append(.text(text, sessionId: session.sessionId))
            return result
        }
        func inject(file url: URL, into session: SessionState, submit: Bool) async -> Result<Void, AgentInjectionService.InjectionError> {
            calls.append(.file(url, sessionId: session.sessionId))
            return result
        }
    }

    private var injector: RecordingInjector!
    private var coordinator: SendToAgentCoordinator!

    override func setUp() async throws {
        injector = RecordingInjector()
        coordinator = SendToAgentCoordinator.shared
        coordinator.injector = injector
        coordinator.dismissPicker()
    }

    override func tearDown() async throws {
        coordinator.dismissPicker()
        coordinator.injector = AgentInjectionService.shared
        coordinator.liveSessionsProvider = { GhostwireSessionBridge.shared.sessionMonitor.instances }
    }

    // MARK: - Single agent: immediate inject

    func testTextPayloadMapsToInjectText() async {
        coordinator.liveSessionsProvider = { [Self.session(id: "only")] }
        let result = await coordinator.send(.text("hello"))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(injector.calls, [.text("hello", sessionId: "only")])
    }

    func testFilePayloadMapsToInjectFile() async {
        coordinator.liveSessionsProvider = { [Self.session(id: "only")] }
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        let result = await coordinator.send(.file(url))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(injector.calls, [.file(url, sessionId: "only")])
    }

    func testInjectionFailurePropagates() async {
        injector.result = .failure(.noDeliverablePath)
        coordinator.liveSessionsProvider = { [Self.session(id: "only")] }
        let result = await coordinator.send(.text("x"))
        XCTAssertEqual(result, .failed)
    }

    // MARK: - No agent: quiet failure

    func testNoLiveAgentFailsQuietly() async {
        coordinator.liveSessionsProvider = { [] }
        let result = await coordinator.send(.text("x"))
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(injector.calls.isEmpty)
        XCTAssertTrue(coordinator.pickerCandidates.isEmpty)
    }

    // MARK: - Several agents, none focused: picker

    func testSeveralUnfocusedRaisesPickerAndHoldsPayload() async {
        let a = Self.session(id: "a")
        let b = Self.session(id: "b")
        coordinator.liveSessionsProvider = { [a, b] }

        let result = await coordinator.send(.text("queued"))
        XCTAssertEqual(result, .awaitingPick)
        XCTAssertEqual(coordinator.pickerCandidates.map(\.sessionId), ["a", "b"])
        // Nothing injected until the user picks.
        XCTAssertTrue(injector.calls.isEmpty)

        // Pick resolves the held payload into the chosen session.
        coordinator.resolvePick(b)
        // resolvePick spawns a Task; drain it.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(injector.calls, [.text("queued", sessionId: "b")])
        XCTAssertTrue(coordinator.pickerCandidates.isEmpty)
    }

    func testDismissPickerDropsPayload() async {
        coordinator.liveSessionsProvider = { [Self.session(id: "a"), Self.session(id: "b")] }
        _ = await coordinator.send(.text("dropped"))
        coordinator.dismissPicker()
        await Task.yield()
        XCTAssertTrue(coordinator.pickerCandidates.isEmpty)
        XCTAssertTrue(injector.calls.isEmpty)
    }

    // MARK: - Helper

    private static func session(id: String) -> SessionState {
        // pid set, plain terminal -> baseline delivery path -> a live target.
        SessionState(sessionId: id, cwd: "/tmp/\(id)", pid: 4321, agent: "claude", phase: .idle)
    }
}
