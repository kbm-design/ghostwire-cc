//
//  GhostwireSkyLightWindow.swift
//  Ghostwire
//
//

import Cocoa
import SkyLightWindow
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class GhostwireSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false

    /// GW-265: gates `canBecomeKey`. The notch is a non-activating panel, but a
    /// key-capable panel can still pull the key window (and thus keyboard focus)
    /// out from under the app you're typing in when a passive reveal renders a
    /// focusable view. So we DENY key by default and only grant it on a real user
    /// click into the notch (set in FirstMouseHostingView.mouseDown) — a passive
    /// auto-open / glow can never steal focus. Reset to false on close.
    /// Touched only on the main thread (AppKit click + view-model close).
    nonisolated(unsafe) static var allowsKeyFocus = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [styleMask, .nonactivatingPanel],
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }
    
    private func setupObservers() {
        // GW-463: ghost mode. Applies the current setting immediately and
        // re-applies it whenever the toggle changes.
        GhostMode.observe(self, storingIn: &observers)
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    override var canBecomeKey: Bool { Self.allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}
