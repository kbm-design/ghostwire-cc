//
//  GhostwireApp.swift
//  Ghostwire
//
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

/// Process entry point. The same signed binary serves two roles:
///  - `Ghostwire mcp-serve` → the GW-173 MCP context-hub server over stdio
///    (no GUI, no AppKit/Sparkle init), so `.withSecurityScope` Shelf bookmarks
///    resolve under the app's own code signature.
///  - otherwise → the normal SwiftUI/menu-bar app.
@main
enum GhostwireMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("mcp-serve") {
            MCPServeRuntime.main()  // never returns
        }
        GhostwireApp.main()
    }
}

struct GhostwireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("Notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Open Shelf Window") {
                DispatchQueue.main.async {
                    ShelfWindowController.shared.showWindow()
                }
            }
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Divider()
            Button("Restart Ghostwire") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// GW-265/GW-264: a real click into the notch is the ONLY thing that grants
    /// the panel key focus (so a passive reveal can never steal it) and marks the
    /// reveal as user-engaged (so the dwell timer stops trying to auto-collapse
    /// it). We grant key here and make the panel key explicitly — AppKit decides
    /// key-ness around the click, so flipping the gate inside mouseDown wouldn't
    /// take effect until the next click. Always forward to super so SwiftUI keeps
    /// its hit-testing / gestures.
    override func mouseDown(with event: NSEvent) {
        GhostwireSkyLightWindow.allowsKeyFocus = true
        if let panel = window, panel.canBecomeKey, !panel.isKeyWindow {
            panel.makeKey()
        }
        NotchRevealController.shared.engaged()
        super.mouseDown(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: GhostwireViewModel] = [:] // UUID -> GhostwireViewModel
    var window: NSWindow?
    let vm: GhostwireViewModel = .init()
    @ObservedObject var coordinator = GhostwireViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    /// GW-286: cursor for "jump to next" — the sessionId we last jumped to, so
    /// repeated presses advance through the pending set and wrap around.
    private var lastJumpedSessionId: String?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?

    private var dragDetectors: [String: DragDetector] = [:]


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        GhostwireSessionBridge.shared.stopMonitoring()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? GhostwireSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? GhostwireSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? GhostwireSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? GhostwireSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame

        // Reveal band tied to the PHYSICAL notch, not the open-notch size.
        // The old 640×190 region (openNotchSize) reached ~190pt down into the
        // work area, so dragging files/windows across the upper-center of the
        // screen toggled the shelf before reaching the notch. Clamp the height
        // hard (menu-bar/notch height + small pad); keep the width forgiving so
        // it's still an easy drop target.
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        let physicalNotchHeight = max(screen.safeAreaInsets.top, menuBarHeight, 32)
        let notchHeight = physicalNotchHeight + 20

        var physicalNotchWidth: CGFloat = 185
        if let topLeftPadding = screen.auxiliaryTopLeftArea?.width,
           let topRightPadding = screen.auxiliaryTopRightArea?.width {
            physicalNotchWidth = screenFrame.width - topLeftPadding - topRightPadding + 4
        }
        let notchWidth = physicalNotchWidth + 160  // ~80pt of slack each side

        // Create reveal region at the top-center of the screen, just below the notch.
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = .shelf
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.open()
            coordinator.currentView = .shelf
        }
    }

    private func createGhostwireWindow(for screen: NSScreen, with viewModel: GhostwireViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = GhostwireSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        let hostingView = FirstMouseHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        window.contentView = hostingView

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }



    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func ensureWindowSize(_ size: CGSize, animated: Bool, force: Bool = false) {
        var targets: [(NSWindow, NSScreen)] = []

        if Defaults[.showOnAllDisplays] {
            for (uuid, window) in windows {
                if let screen = NSScreen.screen(withUUID: uuid) {
                    targets.append((window, screen))
                }
            }
        } else if let window = self.window, let screen = window.screen {
            targets.append((window, screen))
        }

        for (window, screen) in targets {
            if force || window.frame.size != size {
                let screenFrame = screen.frame
                let clampedWidth = min(size.width, screenFrame.width)
                let clampedHeight = min(size.height, screenFrame.height)
                let newX = screenFrame.midX - (clampedWidth / 2)
                let newY = screenFrame.origin.y + screenFrame.height - clampedHeight
                window.setFrame(NSRect(x: newX, y: newY, width: clampedWidth, height: clampedHeight), display: true)
            }
        }
    }



    /// Wire the voice-capture reveal/open/close callbacks to the notch under the
    /// mouse, mirroring the per-display resolution the ⌃⇧Space toggle uses. Both the
    /// toggle handler and the hold-to-talk monitor call this at gesture start, so the
    /// hold path routes onto the right notch instead of dead `{}` closures (GW-270).
    @MainActor
    func wireVoiceCallbacks(forScreenUnder mouseLocation: NSPoint) {
        var viewModel = self.vm
        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
                if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                    viewModel = screenViewModel
                    break
                }
            }
        }

        self.closeNotchTask?.cancel()
        self.closeNotchTask = nil

        // Recording shows an ambient indicator in the CLOSED notch. A finished
        // transcript either pastes into the focused field (notch stays closed) or
        // pops the Shelf open on the right per-display notch. onRequestOpen/Close are
        // only for errors.
        let voice = VoiceCaptureViewModel.shared
        voice.onRevealShelf = { [weak viewModel] in
            guard let viewModel else { return }
            // GW-264: only arm the dwell timer when this reveal actually auto-opens a
            // CLOSED notch — otherwise we'd auto-close one the user opened manually.
            let wasClosed = viewModel.notchState == .closed
            viewModel.open()
            NotchTab.setHidden(.shelf, false)
            GhostwireViewCoordinator.shared.currentView = .shelf
            NotchTab.ensureCurrentViewVisible()
            GhostwireViewCoordinator.shared.pendingShelfReveal = true
            // GW-224: a finished voice capture landing in the Shelf is a user-driven
            // surface use — record it so the next no-alert open returns to the Shelf.
            GhostwireViewCoordinator.shared.lastSelectedTab = .shelf
            // GW-264: INFORMATIONAL reveal — auto-collapse after the info dwell unless
            // the user engages it.
            if wasClosed {
                NotchRevealController.shared.reveal(.informational, target: viewModel)
            }
        }
        voice.onRequestOpen = { [weak viewModel] in viewModel?.open() }
        voice.onRequestClose = { [weak viewModel] in viewModel?.close() }
    }

    // MARK: - GW-286 tab-open / jump-to-approval hotkeys

    /// Resolve the GhostwireViewModel for the notch under the mouse — mirrors
    /// the per-display resolution used by toggleNotchOpen / openClipboardHistory.
    @MainActor
    private func viewModelUnderMouse() -> GhostwireViewModel {
        var viewModel = self.vm
        if Defaults[.showOnAllDisplays] {
            let mouseLocation = NSEvent.mouseLocation
            for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
                if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                    viewModel = screenViewModel
                    break
                }
            }
        }
        return viewModel
    }

    /// GW-286: open the notch on a specific tab. Unhides the tab if the user hid
    /// it, lands on it, and records it as the last-used surface (GW-224). No
    /// auto-close timer — a hand-triggered open stays put until acted on.
    @MainActor
    private func openNotch(onTab tab: NotchTab) {
        let viewModel = viewModelUnderMouse()
        closeNotchTask?.cancel()
        closeNotchTask = nil

        viewModel.open()
        // A hotkey open is a deliberate, sticky open — mark it engaged so a
        // stale auto-reveal dwell timer (from a prior approval) can't collapse
        // the notch out from under it.
        NotchRevealController.shared.engaged()
        NotchTab.setHidden(tab, false)
        coordinator.currentView = tab.view
        NotchTab.ensureCurrentViewVisible()
        // GW-267: Open-on-Agents lands on the instances LIST. If you were drilled
        // into a chat, back out to it — a reliable "get me back to the list"
        // fail-safe (esp. to leave an approval chat that's still up).
        if tab == .agents {
            GhostwireSessionBridge.shared.panelViewModel.exitChat()
        }
        // GW-224: a deliberate open-on-tab is user-driven surface use, so it
        // becomes the "reopen here" memory for the next no-alert open.
        coordinator.lastSelectedTab = tab.view
    }

    /// GW-286/GW-267: open the notch on Agents and drill into the next session
    /// that needs you, cycling in order (remembering the last jump so repeated
    /// presses advance and wrap). Navigation ONLY — never writes a verdict.
    ///
    /// `approvalsOnly` narrows the cycle to pending approvals — used by the
    /// Approve/Deny reveal-fallback, which is specifically hunting an approval to
    /// act on. The Jump hotkey passes `false` to cycle EVERYTHING needing
    /// attention (approvals AND waiting-for-input questions), so you can triage
    /// the whole queue by keyboard. No-ops when nothing's pending.
    @MainActor
    private func jumpToNext(approvalsOnly: Bool) {
        let all = GhostwireSessionBridge.shared.sessionMonitor.pendingInstances
        let candidates = approvalsOnly ? all.filter { $0.activePermission != nil } : all
        guard !candidates.isEmpty else { return }

        // Where are we now? Prefer the chat currently on screen so a press
        // advances PAST what you're looking at, then fall back to the last jump
        // cursor. (Without this, pressing Jump while already in a target's chat
        // targets that same session and no-ops — feels dead.)
        let currentSessionId: String?
        if case .chat(let shown) = GhostwireSessionBridge.shared.panelViewModel.contentType,
           candidates.contains(where: { $0.sessionId == shown.sessionId }) {
            currentSessionId = shown.sessionId
        } else {
            currentSessionId = lastJumpedSessionId
        }

        let nextIndex: Int
        if let current = currentSessionId,
           let i = candidates.firstIndex(where: { $0.sessionId == current }) {
            nextIndex = (i + 1) % candidates.count
        } else {
            nextIndex = 0
        }
        let target = candidates[nextIndex]
        lastJumpedSessionId = target.sessionId

        let viewModel = viewModelUnderMouse()
        closeNotchTask?.cancel()
        closeNotchTask = nil

        viewModel.open()
        // A deliberate jump is a sticky open — mark engaged so a stale
        // auto-reveal dwell can't collapse it (GW-264).
        NotchRevealController.shared.engaged()
        // Reuse the approval-reveal path: ensure Agents is reachable, land on
        // it, and drill into the target's chat. Like the auto-reveal, this does
        // NOT overwrite lastSelectedTab — answering/leaving a request must not
        // strand the next no-alert open on Agents (GW-224).
        NotchTab.ensureAgentsVisibleForApproval()
        coordinator.showAgentsForApproval()
        GhostwireSessionBridge.shared.panelViewModel.showChat(for: target)
    }

    /// GW-267: the session whose chat is currently shown in the OPEN notch
    /// (Agents tab, drilled in), refreshed from the live instance list. nil if
    /// the notch is closed, not on Agents, or not in a chat — so the quick-action
    /// keys below only fire when a request is genuinely in front of you.
    @MainActor
    private func focusedChatSession() -> SessionState? {
        // A closed notch can still hold a stale `.chat` content type, so the
        // notch must actually be open (on any display) before we trust it.
        let anyNotchOpen = vm.notchState == .open
            || viewModels.values.contains { $0.notchState == .open }
        guard anyNotchOpen,
              coordinator.currentView == .buddy,   // Agents tab is the one showing
              case .chat(let shown) = GhostwireSessionBridge.shared.panelViewModel.contentType,
              let live = GhostwireSessionBridge.shared.sessionMonitor.instances
                  .first(where: { $0.sessionId == shown.sessionId })
        else { return nil }
        return live
    }

    /// GW-267: approve/deny the approval in the focused chat. If a pending
    /// approval is in front of you, act on it (same verdict path as the notch
    /// buttons — never a blind auto-approve). If NOT — you're on the list, the
    /// notch is closed, or the chat has nothing pending — this first press just
    /// REVEALS the next pending approval (same as Jump); a second press, now
    /// looking at it, confirms. So Approve/Deny double as "reveal-then-act" and
    /// never act on something you can't see.
    @MainActor
    private func resolveFocusedApproval(approve: Bool) {
        guard let session = focusedChatSession(), session.activePermission != nil else {
            // Nothing actionable in front of you → reveal the next APPROVAL
            // instead (you're hunting one to act on, so skip plain questions).
            jumpToNext(approvalsOnly: true)
            return
        }
        let monitor = GhostwireSessionBridge.shared.sessionMonitor
        if approve {
            monitor.approvePermission(sessionId: session.sessionId)
        } else {
            monitor.denyPermission(sessionId: session.sessionId, reason: nil)
        }
    }

    /// GW-267: focus the terminal for the session whose chat is in front of you
    /// (pending or not — pure navigation). No-op if no focused chat.
    @MainActor
    private func openTerminalForFocusedSession() {
        guard let session = focusedChatSession() else { return }
        Task { await SessionFocusController.shared.focus(session: session) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // GW-210: open the notch on the Shelf tab and land on clipboard history.
        // Mirrors .toggleNotchOpen's per-display view-model resolution, then
        // routes to the Shelf tab + asks ShelfView to show the clipboard view.
        KeyboardShortcuts.onKeyDown(for: .openClipboardHistory) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation
                var viewModel = self.vm
                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
                        if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                            viewModel = screenViewModel
                            break
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                viewModel.open()
                // The Shelf tab is the clipboard host; make sure it's reachable
                // (unhide if the user hid it) before landing on it. The Shelf
                // module master toggle (Defaults[.shelf]) still wins — if the
                // whole Shelf is off, ensureCurrentViewVisible falls back and
                // requestClipboardHistory is harmlessly ignored.
                NotchTab.setHidden(.shelf, false)
                self.coordinator.currentView = .shelf
                NotchTab.ensureCurrentViewVisible()
                // GW-224: opening clipboard history is a user-driven surface use,
                // so it becomes the "reopen here" memory for the next no-alert open.
                self.coordinator.lastSelectedTab = .shelf
                self.coordinator.requestClipboardHistory = true
            }
        }

        // GW-286: open the notch directly on a tab. Mirrors openClipboardHistory's
        // per-display view-model resolution, then routes to the requested tab.
        // A deliberate hotkey is user-driven surface use, so (like clipboard
        // history) it becomes the "reopen here" memory for the next no-alert open
        // (GW-224). No auto-close timer — a hand-triggered open stays put.
        KeyboardShortcuts.onKeyDown(for: .openNotchAgents) { [weak self] in
            Task { @MainActor [weak self] in self?.openNotch(onTab: .agents) }
        }
        KeyboardShortcuts.onKeyDown(for: .openNotchShelf) { [weak self] in
            Task { @MainActor [weak self] in self?.openNotch(onTab: .shelf) }
        }
        KeyboardShortcuts.onKeyDown(for: .openNotchDashboard) { [weak self] in
            Task { @MainActor [weak self] in self?.openNotch(onTab: .dashboard) }
        }

        // GW-286: jump to the next pending approval. Opens the notch on Agents
        // and drills into the next waiting session's chat (where Allow/Deny
        // lives). Navigation ONLY — never writes a verdict. No-ops when nothing
        // is pending (don't pop an empty Agents tab).
        KeyboardShortcuts.onKeyDown(for: .jumpToNextPendingApproval) { [weak self] in
            Task { @MainActor [weak self] in self?.jumpToNext(approvalsOnly: false) }
        }

        // GW-267: keyboard quick-actions on the approval you're looking at.
        // Each is a no-op unless the notch is open on a pending approval's
        // focused chat (resolveFocusedApproval / openTerminalForFocusedSession
        // enforce that gate). Approve/Deny route through the SAME verdict path
        // as the notch buttons; never a blind/auto-approve.
        KeyboardShortcuts.onKeyDown(for: .approveFocusedApproval) { [weak self] in
            Task { @MainActor [weak self] in self?.resolveFocusedApproval(approve: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .denyFocusedApproval) { [weak self] in
            Task { @MainActor [weak self] in self?.resolveFocusedApproval(approve: false) }
        }
        KeyboardShortcuts.onKeyDown(for: .openTerminalForFocusedSession) { [weak self] in
            Task { @MainActor [weak self] in self?.openTerminalForFocusedSession() }
        }

        // GW-229: toggle voice capture. Opens the notch as an overlay (the panel
        // is non-activating, so the foreground app stays put) and toggles the
        // recorder. The capture flow resolves the target agent in-notch, so no
        // tab switch is needed — the overlay floats over whatever tab is shown.
        KeyboardShortcuts.onKeyDown(for: .toggleVoiceCapture) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard Defaults[.voiceCaptureEnabled] else { return }
                self.wireVoiceCallbacks(forScreenUnder: NSEvent.mouseLocation)
                await VoiceCaptureViewModel.shared.toggle()
            }
        }

        // GW-270: hold-to-talk (push-to-talk). The monitor owns the CGEventTap for
        // the held modifier; at gesture start it wires the same per-display callbacks
        // as the toggle so begin()/release route onto the notch under the mouse. It
        // self-gates on Defaults (voice off or key == .off ⇒ tap not running).
        HoldToTalkMonitor.shared.prepareForGesture = { [weak self] in
            self?.wireVoiceCallbacks(forScreenUnder: NSEvent.mouseLocation)
        }
        HoldToTalkMonitor.shared.reconfigure()

        // GW-270: normalize a stale/unknown voiceModel rawValue (e.g. a renamed
        // engine from an older build) back to the default — otherwise the Settings
        // engine picker renders blank and the stored value is invalid (recording
        // still falls back to Nemotron, but the UI looks broken).
        let storedVoiceModel = Defaults[.voiceModel]
        if storedVoiceModel != DefaultTranscriberFactory.appleEngineKey,
           VoiceModel(rawValue: storedVoiceModel) == nil {
            Defaults[.voiceModel] = VoiceModel.nemotronEN.rawValue
        }

        // GW-270: voice is OPT-IN (off by default), so if it's ON the user explicitly
        // asked for it — make sure the model is present + warm every launch so the
        // first gesture is never a cold "Preparing…" / empty miss (which a user might
        // read as "it didn't work", and that may be the only time they try it).
        // prepare() → ensureLoaded() downloads ONLY when the on-disk cache is actually
        // missing (fresh enable, disk wipe), then loads; it no-ops once loaded. Users
        // who never turned voice on pay nothing. (This is intended for opt-in voice —
        // not the GW-229 "never pull at launch" world where voice was on by default.)
        if Defaults[.voiceCaptureEnabled] {
            let selected = Defaults[.voiceModel]
            if selected != DefaultTranscriberFactory.appleEngineKey,
               let model = VoiceModel(rawValue: selected) {
                FluidAudioTranscriber.prepare(model)
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            GhostwireSessionBridge.shared.ghostwireViewModel = viewModel
            let window = createGhostwireWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
        AgentHookConfig.installEnabledAgents()
        AlertHistoryStore.shared.warm()
        ClipboardHistoryService.shared.start()  // GW-210: follows the master toggle (default off)
        AmbientContextService.shared.start()  // GW-172: Tier-0 frontmost-app spine (silent; default on)
        GhostwireSessionBridge.shared.startMonitoring()
        GatewayHTTPService.startIfEnabled()  // GW-253: localhost MCP gateway (opt-in)
        UsageService.shared.startPolling()
        CodexUsageService.shared.startPolling()
        FeedSourceCoordinator.shared.start()  // GW-261: built-in keyless feed sources (crypto + RSS)






    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "Ghostwire", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = GhostwireViewModel(screenUUID: uuid)
                    let window = createGhostwireWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }

            let primaryScreenUUID = coordinator.selectedScreenUUID.isEmpty
                ? NSScreen.main?.displayUUID
                : coordinator.selectedScreenUUID
            GhostwireSessionBridge.shared.ghostwireViewModel = primaryScreenUUID.flatMap { viewModels[$0] } ?? viewModels.values.first
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createGhostwireWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }

            GhostwireSessionBridge.shared.ghostwireViewModel = vm
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
