//
//  AmbientContextService.swift
//  Ghostwire
//
//  GW-172 — the Tier-0 frontmost-app observer. Event-driven first: every app
//  switch arrives pushed via NSWorkspace.didActivateApplicationNotification; a
//  sparse backstop poll (90s) only extends streaks and samples idle when no
//  switch fires. Free — zero TCC, no permission prompt (all public API).
//
//  Idle: system-wide seconds since the last input of ANY type via
//  CGEventSource (no Accessibility). Power: NSWorkspace willSleep/didWake — we
//  never record to an asleep/empty chair, and the max-gap rule (ContextStore)
//  starts a fresh streak after the absence rather than extending across it.
//
//  Snapshot = (frontmost app, bundleID, idleSeconds). Fingerprint = bundleID
//  only — window titles / tab hosts are Tier-1 (GW-182+). SILENT: capture +
//  store only, no surfacing. Local-only — never narrated to a cloud agent.
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation

@MainActor
final class AmbientContextService {
    static let shared = AmbientContextService()

    /// Backstop poll interval — events are primary; this only extends streaks /
    /// samples idle when the user sits in one app (architecture §2).
    static let backstopInterval: TimeInterval = 90

    private let store: ContextStore
    private let workspace: NSWorkspace
    private let idleProvider: () -> TimeInterval

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var enabledCancellable: AnyCancellable?
    private var retentionCancellable: AnyCancellable?
    private var asleep = false

    init(
        store: ContextStore = .shared,
        workspace: NSWorkspace = .shared,
        idleProvider: @escaping () -> TimeInterval = AmbientContextService.systemIdleSeconds
    ) {
        self.store = store
        self.workspace = workspace
        self.idleProvider = idleProvider
    }

    /// System-wide idle seconds — time since the last input event of ANY type
    /// (`kCGAnyInputEventType` == ~0). No AX, no TCC prompt.
    static func systemIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    /// Start observing, following the capture master toggle live. Safe at launch.
    func start() {
        store.warm()
        enabledCancellable = Defaults.publisher(.ambientCaptureEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue { self?.startObserving() } else { self?.stopObserving() }
                }
            }
        // Switching retention to session-only wipes shards already on disk
        // (memory keeps the current session).
        retentionCancellable = Defaults.publisher(.ambientRetention)
            .sink { [weak self] change in
                guard change.newValue == .sessionOnly else { return }
                Task { @MainActor in self?.store.deleteAllPersisted() }
            }
        if Defaults[.ambientCaptureEnabled] { startObserving() }
    }

    // MARK: - Observation lifecycle

    private func startObserving() {
        guard activationObserver == nil else { return }
        let nc = workspace.notificationCenter

        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.capture(app: app) }
        }
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.asleep = true }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.asleep = false
                self?.capture(app: nil)  // re-anchor on wake (max-gap → fresh streak)
            }
        }

        capture(app: workspace.frontmostApplication)  // seed with what's frontmost now
        startTimer()
    }

    private func stopObserving() {
        let nc = workspace.notificationCenter
        [activationObserver, sleepObserver, wakeObserver]
            .compactMap { $0 }
            .forEach(nc.removeObserver)
        activationObserver = nil
        sleepObserver = nil
        wakeObserver = nil
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.backstopInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.capture(app: nil) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Capture

    /// Build a snapshot from the activated (or current frontmost) app and fold it
    /// into the store, after the capture filter. No-op when asleep or disabled.
    private func capture(app providedApp: NSRunningApplication?) {
        guard !asleep, Defaults[.ambientCaptureEnabled] else { return }
        guard let app = providedApp ?? workspace.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }

        let denylist = Set(Defaults[.ambientAppDenylist])
        guard ContextStreak.shouldCapture(bundleID: bundleID, denylist: denylist) else { return }

        store.record(ContextSnapshot(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            idleSeconds: idleProvider(),
            capturedAt: Date()
        ))
    }
}
