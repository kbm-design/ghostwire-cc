//
//  SendToAgentCoordinator.swift
//  Ghostwire
//
//  GW-163: the one place a piece of held content (clipboard entry, shelf tile,
//  chat attachment) is routed to a live agent's input. Wires the GW-164 seams
//  together: resolve the active target with `AgentTargetResolver`, then hand the
//  payload to `AgentInjectionService`. Never auto-submits — the text/`@path`
//  lands in the agent's input for the human to send (the inject service default).
//
//  Resolution outcomes (AgentTargetResolver):
//    - .single / .focused  -> inject immediately, report success/failure
//    - .candidates         -> publish the candidate sessions; the notch shows a
//                             compact picker (SendToAgentPicker); the user's pick
//                             resolves the pending payload
//    - .none               -> quiet failure (the call site shows a brief hint /
//                             the picker never appears). No modal, no alert.
//
//  The live session list is read from the same source the Agents tab uses
//  (`GhostwireSessionBridge.shared.sessionMonitor.instances`), so the picker and
//  the resolver see exactly what the user sees in the notch.
//

import Foundation
import SwiftUI

@MainActor
final class SendToAgentCoordinator: ObservableObject {
    static let shared = SendToAgentCoordinator()

    /// What is being sent. Mirrors the two inject entry points: a literal
    /// string (text / link URL) or a file reference (`@path`).
    enum Payload: Equatable {
        case text(String)
        case file(URL)
    }

    /// Outcome of a send attempt — drives the call site's quiet feedback.
    enum SendResult: Equatable {
        /// Landed in the (single/focused) agent's input.
        case delivered
        /// Several live agents and none focused — a picker is now showing; the
        /// outcome depends on the user's pick (handled inside the coordinator).
        case awaitingPick
        /// No live agent to reach, or the delivery path failed.
        case failed
    }

    // MARK: - Picker state (observed by the notch overlay)

    /// The live sessions to disambiguate between. Non-empty -> the picker shows.
    @Published private(set) var pickerCandidates: [SessionState] = []

    /// The payload waiting on a pick. Held while `pickerCandidates` is non-empty.
    private var pendingPayload: Payload?

    private init() {}

    /// Injection service seam — swappable for tests.
    var injector: AgentInjecting = AgentInjectionService.shared

    /// Live session source — swappable for tests. Defaults to the same list the
    /// Agents tab renders.
    var liveSessionsProvider: () -> [SessionState] = {
        GhostwireSessionBridge.shared.sessionMonitor.instances
    }

    // MARK: - Send

    /// Resolve the active agent and route `payload` to it. Single/focused inject
    /// immediately; several-with-none-focused raises the picker; none fails
    /// quietly. Returns the immediate outcome (`.awaitingPick` when the picker
    /// is now showing).
    @discardableResult
    func send(_ payload: Payload) async -> SendResult {
        let sessions = liveSessionsProvider()
        let target = await AgentTargetResolver.resolveActiveTarget(from: sessions)

        switch target {
        case .single(let id), .focused(let id):
            guard let session = sessions.first(where: { $0.sessionId == id }) else {
                return .failed
            }
            return await deliver(payload, to: session)

        case .candidates(let ids):
            let candidates = ids.compactMap { id in sessions.first { $0.sessionId == id } }
            guard !candidates.isEmpty else { return .failed }
            pendingPayload = payload
            pickerCandidates = candidates
            return .awaitingPick

        case .none:
            return .failed
        }
    }

    /// Convenience wrappers mirroring the inject entry points.
    @discardableResult func sendText(_ text: String) async -> SendResult { await send(.text(text)) }
    @discardableResult func sendFile(_ url: URL) async -> SendResult { await send(.file(url)) }

    // MARK: - Picker resolution

    /// The user picked a candidate from the notch picker. Inject the held
    /// payload into it and dismiss.
    func resolvePick(_ session: SessionState) {
        let payload = pendingPayload
        dismissPicker()
        guard let payload else { return }
        Task { await deliver(payload, to: session) }
    }

    /// The user dismissed the picker without choosing — drop the held payload.
    func dismissPicker() {
        pendingPayload = nil
        pickerCandidates = []
    }

    // MARK: - Delivery

    private func deliver(_ payload: Payload, to session: SessionState) async -> SendResult {
        let result: Result<Void, AgentInjectionService.InjectionError>
        switch payload {
        case .text(let string):
            result = await injector.inject(text: string, into: session, submit: false)
        case .file(let url):
            result = await injector.inject(file: url, into: session, submit: false)
        }
        switch result {
        case .success:
            return .delivered
        case .failure:
            return .failed
        }
    }
}

// MARK: - Injection seam (test double point)

/// The slice of `AgentInjectionService` the coordinator depends on. Lets tests
/// substitute a recording double without touching the real terminal.
protocol AgentInjecting: Sendable {
    func inject(text: String, into session: SessionState, submit: Bool) async -> Result<Void, AgentInjectionService.InjectionError>
    func inject(file url: URL, into session: SessionState, submit: Bool) async -> Result<Void, AgentInjectionService.InjectionError>
}

extension AgentInjectionService: AgentInjecting {}
