//
//  NotchRevealController.swift
//  Ghostwire
//
//  GW-264 / GW-227: the @MainActor driver that turns the pure `NotchRevealMachine`
//  into real behavior — a dwell timer that collapses an auto-reveal on its own,
//  pauses while the user hovers, and restarts on mouse-out (WCAG 2.2.1).
//
//  It owns nothing the machine decides; it only maps the machine's `Effect`s onto
//  a timer Task and a notch close. The "recede to glow" half of an actionable
//  collapse is handled separately and automatically: the persistent passive glow
//  is driven by live pending-approval state (GhostwireSessionBridge), so simply
//  closing the panel while an approval is still pending leaves the glow/badge up
//  and the request in the Agents tab. Collapsing the panel never dismisses the
//  request.
//

import Defaults
import Foundation

@MainActor
final class NotchRevealController {
    static let shared = NotchRevealController()

    /// Close the notch that was actually revealed. Injected so tests (and
    /// previews) don't need a live window; the default closes the passed view
    /// model (the specific per-display notch that auto-opened), falling back to
    /// the bridge's current one. Scoping to the revealed VM matters under
    /// Show-on-All-Displays, where the reveal can open a non-primary notch.
    var closeNotch: (GhostwireViewModel?) -> Void = { viewModel in
        (viewModel ?? GhostwireSessionBridge.shared.ghostwireViewModel)?.close()
    }

    /// The view model whose notch this dwell is responsible for collapsing.
    private weak var revealedViewModel: GhostwireViewModel?

    /// Dwell durations (seconds) per reveal class. Injected for tests; defaults
    /// read the user's settings.
    var dwellSeconds: (NotchRevealClass) -> Double = { reveal in
        switch reveal {
        case .informational: return Defaults[.notchInfoDwellSeconds]
        case .actionable: return Defaults[.notchActionableDwellSeconds]
        }
    }

    private var machine = NotchRevealMachine()
    private var timerTask: Task<Void, Never>?
    /// Bumped whenever the timer is (re)started or cancelled, so a sleep that
    /// resumes after its timer was replaced detects it's stale and drops out.
    private var generation = 0

    /// Internal so tests can drive a private instance. The test host is the live
    /// app: its notch hover (`ContentView`) and bridge reveals hit `.shared`
    /// concurrently with a test, so a test on the singleton is a test of the
    /// cursor's position (GW-444).
    init() {}

    // MARK: - Inputs (from the reveal sites / hover)

    /// A passive reveal fired — begin the dwell for its class. `target` is the
    /// view model whose notch was opened (the one to collapse on expiry); pass
    /// the specific per-display VM so the right notch closes.
    func reveal(_ revealClass: NotchRevealClass, target: GhostwireViewModel? = nil) {
        revealedViewModel = target
        apply(machine.handle(.reveal(revealClass)))
    }

    /// Hover/interaction began or ended — pause / restart the countdown.
    func hoverChanged(_ hovering: Bool) {
        apply(machine.handle(.hoverChanged(hovering)))
    }

    /// The user took the notch over (tap/click) — it becomes a sticky open and
    /// the dwell no longer governs it.
    func engaged() {
        apply(machine.handle(.engaged))
    }

    /// The notch was closed by some other path — drop any pending dwell so a
    /// stale timer can't re-close a freshly reopened notch.
    func dismissed() {
        apply(machine.handle(.dismissed))
    }

    // MARK: - Effect application

    private func apply(_ effect: NotchRevealMachine.Effect) {
        switch effect {
        case .startTimer(let revealClass):
            startTimer(for: revealClass)
        case .cancelTimer:
            cancelTimer()
        case .collapse(let toGlow):
            cancelTimer()
            // Informational and actionable both just close the panel. For
            // actionable (toGlow), the persistent passive glow + the pending row
            // in the Agents tab remain — the request is never dropped.
            _ = toGlow
            closeNotch(revealedViewModel)
            revealedViewModel = nil
        case .none:
            break
        }
    }

    private func startTimer(for revealClass: NotchRevealClass) {
        generation &+= 1
        let gen = generation
        let seconds = max(0, dwellSeconds(revealClass))
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                self.apply(self.machine.handle(.timerFired))
            }
        }
    }

    private func cancelTimer() {
        generation &+= 1
        timerTask?.cancel()
        timerTask = nil
    }
}
