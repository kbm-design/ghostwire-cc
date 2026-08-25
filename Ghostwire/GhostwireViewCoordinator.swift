//
//  GhostwireViewCoordinator.swift
//  Ghostwire
//
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
    case buddy
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class GhostwireViewCoordinator: ObservableObject {
    static let shared = GhostwireViewCoordinator(observeSystemState: true)

    @Published var currentView: NotchViews = .buddy
    /// GW-210: set by the `openClipboardHistory` hotkey to ask the Shelf tab to
    /// land directly on the clipboard-history swap-view. ShelfView consumes
    /// (and resets) it on appear/change so a later plain Shelf open is unaffected.
    @Published var requestClipboardHistory: Bool = false
    /// GW-224: the baseline "reopen here" surface when there's no last-used
    /// memory yet. Shelf — the utility home — NOT Agents: a no-alert open must
    /// never default to the approval surface (restores GW-203's shelf-by-default
    /// intent that GW-226 overcorrected into always-Agents).
    static let defaultLastSelectedTab: NotchViews = .shelf

    /// GW-226/GW-224: the last surface the user actually used. The default-open
    /// policy falls back to this so the notch reopens where you left off. Updated
    /// by an explicit tab tap (TabSelectionView) AND by user-driven surface
    /// reveals (voice → Shelf, clipboard history, drag-to-Shelf) — so "last used"
    /// tracks real usage, not just taps. An approval-driven Agents jump never
    /// overwrites it (so dismissing an approval doesn't strand you on Agents).
    @Published var lastSelectedTab: NotchViews = GhostwireViewCoordinator.defaultLastSelectedTab
    /// GW-226: one-shot — armed when the user explicitly saves/drags something to
    /// the Shelf, consumed by the very next open so you see what you just saved,
    /// then it reverts to `lastSelectedTab`. Clipboard auto-capture must NOT arm it.
    var pendingShelfReveal: Bool = false
    @Published var helloAnimationRunning: Bool = false
    @Published var buddyPanelHeight: CGFloat = 350
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                // GW-203/GW-226: route through the single default-view policy
                // instead of hard-setting .buddy - this path bypassed the
                // last-tab / agents-first rule before.
                applyDefaultViewOnOpen()
            }
        }
    }

    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?
    private var notchTabsCancellable: AnyCancellable?

    /// `observeSystemState: false` builds a coordinator that only keeps
    /// `currentView` on a visible tab — no screen migration, no Accessibility /
    /// media-key observers, no startup task. That is the test seam (GW-472): the
    /// XCTest host is the live app, so a test on `.shared` races the real notch
    /// UI for `currentView`. Production always goes through `.shared`.
    init(observeSystemState: Bool = false) {
        // Keep currentView on a visible tab when tab visibility changes via
        // paths that bypass NotchTab.setHidden — the Shelf module toggle and
        // any direct writes to the tab prefs (GW-144).
        notchTabsCancellable = Defaults.publisher(keys: .shelf, .hiddenNotchTabs, .notchTabOrder)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    NotchTab.ensureCurrentViewVisible(coordinator: self)
                }
            }

        guard observeSystemState else { return }

        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                if expandingView.type == .buddy { return }
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    /// GW-203: the single source of truth for which tab a fresh open lands on.
    /// ALL open/close paths route through this - close() (preparing the next
    /// open), showEmpty(), and the alwaysShowTabs toggle - so none of them can
    /// bypass the shelf-by-default / agents-first (GW-199 idle) rule by
    /// hard-setting .buddy.
    ///
    /// GW-226: applies the default-open policy and consumes the one-shot Shelf
    /// reveal. Runs on close (prepares the next open) and at the approval-driven
    /// open in GhostwireSessionBridge.
    func applyDefaultViewOnOpen() {
        currentView = defaultViewOnOpen()
        pendingShelfReveal = false   // GW-226: one-shot consumed
        NotchTab.ensureCurrentViewVisible(coordinator: self)
    }

    /// GW-224 default-open policy (priority order), pure read - the one-shot is
    /// consumed by the caller (`applyDefaultViewOnOpen`):
    ///  1. A one-shot Shelf reveal (you just saved/dragged something) → Shelf.
    ///  2. Otherwise → the last surface you used (if still visible).
    ///  3. Fallback → first visible tab, preferring Shelf (never default a
    ///     no-alert open to Agents); first visible / .shelf as last resort.
    ///
    /// A pending approval deliberately does NOT force Agents here. Forcing Agents
    /// is the job of `showAgentsForApproval()`, called only by the event-driven
    /// AUTO-REVEAL (GhostwireSessionBridge) at the moment an alert arrives. Once
    /// you've navigated away from an approval you're choosing not to answer yet,
    /// reopening respects your last-used tab instead of trapping you on Agents —
    /// the pending row stays in the Agents tab (with its glow/badge) regardless.
    func defaultViewOnOpen() -> NotchViews {
        let visible = NotchTab.currentlyVisible
        if pendingShelfReveal, visible.contains(.shelf) {
            return .shelf
        }
        if visible.contains(where: { $0.view == lastSelectedTab }) {
            return lastSelectedTab
        }
        return visible.first(where: { $0 == .shelf })?.view
            ?? visible.first?.view
            ?? Self.defaultLastSelectedTab
    }

    /// GW-224: route a fresh approval ALERT to the Agents tab — but only at the
    /// moment it auto-reveals. Manual reopens go through `defaultViewOnOpen()`,
    /// which respects your last-used tab, so an approval you're ignoring on
    /// purpose never re-hijacks the notch onto Agents. A live alert supersedes a
    /// queued one-shot Shelf reveal.
    func showAgentsForApproval() {
        if let agents = NotchTab.currentlyVisible.first(where: { $0 == .agents }) {
            currentView = agents.view
        }
        pendingShelfReveal = false
        NotchTab.ensureCurrentViewVisible(coordinator: self)
    }

    func showEmpty() {
        applyDefaultViewOnOpen()
    }
}
