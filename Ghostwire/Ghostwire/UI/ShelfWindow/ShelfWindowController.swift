//
//  ShelfWindowController.swift
//  Ghostwire
//
//  GW-223. The detached Shelf surface: a real, resizable NSWindow that renders
//  the unified card store as a full multi-column grid — the "break out of the
//  notch into a destination" view (the launcher parked as out-of-scope on
//  GW-218). Modeled on `SettingsWindowController`: a shared NSWindowController
//  that flips the app to `.regular` while visible and back to `.accessory` on
//  close, hosting a SwiftUI view via NSHostingView.
//
//  The window shell is intentionally generic (a titled/resizable frame over a
//  SwiftUI content view with size persistence) so it can later host other
//  destinations — e.g. the MCP display (GW-214) — without reworking the chrome.
//  Kept concrete for now; not prematurely abstracted.
//

import AppKit
import SwiftUI

final class ShelfWindowController: NSWindowController {
    static let shared = ShelfWindowController()

    /// Native frame autosave key — persists size + position across launches with
    /// no extra Defaults plumbing.
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("GhostwireShelfWindow")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        guard let window else { return }

        window.title = "Ghostwire"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 420)

        // Solid black canvas to match the notch panel (no under-window vibrancy
        // bleed-through). The SwiftUI root paints black; the window backs it so
        // resize/letterbox gaps stay black too.
        window.isOpaque = true
        window.backgroundColor = .black

        // The cards assume a dark canvas (white-opacity fills, dark hairlines), so
        // force a dark appearance regardless of the system setting.
        window.appearance = NSAppearance(named: .darkAqua)

        // Behave like a normal app window with proper Spaces support (so it shows
        // in Mission Control / cmd-tab and isn't tied to the notch's CGSSpace).
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("GhostwireShelfWindow")

        let hostingView = NSHostingView(rootView: GhostwireWindowView())
        window.contentView = hostingView

        // Restore the saved frame if there is one; otherwise center the default.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        window.delegate = self
    }

    func showWindow() {
        guard let window else { return }

        NSApp.setActivationPolicy(.regular)

        // Already up → just bring it forward, no entrance animation.
        if window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Quick fade-in (160ms, punchy ease-out). Subtle polish without the lag of
        // a heavier transition; deliberately NOT a scale-from-notch choreography
        // (fragile across the panel→window boundary — revisit with GW-222).
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            window.animator().alphaValue = 1
        }
    }

    override func close() {
        super.close()
        relinquishFocusIfNeeded()
    }

    /// Drop the app back to `.accessory` so it returns to a menu-bar agent — but
    /// only if no other standard window (e.g. Settings) is still up, so closing
    /// the Shelf doesn't yank another window's activation out from under it.
    private func relinquishFocusIfNeeded() {
        window?.orderOut(nil)
        let othersVisible = NSApp.windows.contains { other in
            other != window && other.isVisible && other.canBecomeMain
        }
        if !othersVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension ShelfWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocusIfNeeded()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
