//
//  GhostMode.swift
//  Ghostwire
//
//  GW-463: exclude Ghostwire's own windows from screen shares, recordings and
//  screenshots while leaving them fully visible on the user's own screen.
//
//  Every Ghostwire surface is sensitive by nature — a pending gate carries the
//  command and diff an agent wants to run, the Shelf holds files and text, and
//  clipboard history holds whatever was last copied. All of it is on screen by
//  design, which means all of it is in any capture of that screen.
//
//  The mechanism is one AppKit property, `NSWindow.sharingType`. There is no
//  supported way to exclude a window from another app's ScreenCaptureKit capture
//  beyond this, so this file is the whole feature; the interesting part of the
//  ticket is the measurement, not the code.
//
//  Scope is deliberately the two surfaces that carry content: the notch panels
//  (all of them — one per screen when "show on all displays" is on) and the
//  unified window. Onboarding, NSAlerts, open/save panels, QuickLook and
//  Sparkle's update windows are AppKit- or vendor-owned chrome that shows no
//  agent or Shelf content, and are left capturable.
//

import AppKit
import Combine
import Defaults

enum GhostMode {
    /// The user-facing toggle, Settings → Advanced → Window Behavior.
    static var isEnabled: Bool { Defaults[.hideFromScreenRecording] }

    /// `.none` is what actually excludes a window from capture.
    ///
    /// The "off" value is `.readOnly` — AppKit's documented default — and not
    /// `.readWrite`, which is deprecated as of macOS 15 in favour of exactly
    /// this value (`NSWindow.h`: `API_DEPRECATED("Use NSWindowSharingReadOnly
    /// instead", macos(10.5, 15.0))`).
    static var sharingType: NSWindow.SharingType { isEnabled ? .none : .readOnly }

    /// Applies the current setting once.
    static func apply(to window: NSWindow) {
        window.sharingType = sharingType
    }

    /// Applies the current setting and re-applies it whenever the toggle changes,
    /// so ghost mode takes effect live rather than on the next launch.
    ///
    /// The first apply is done here, synchronously, rather than being left to the
    /// publisher's `.initial` emission — both call sites subscribe from inside
    /// window construction and must be ghosted before the window is ever ordered
    /// in. `.dropFirst()` then discards that duplicate initial value.
    ///
    /// `Defaults.publisher` is KVO-backed and delivers on whichever thread wrote
    /// the key, but `sharingType` is main-thread-only AppKit state — hence the
    /// hop. Every writer today is the Settings toggle; this keeps the next one
    /// from being a silent bug.
    static func observe(_ window: NSWindow, storingIn bag: inout Set<AnyCancellable>) {
        apply(to: window)

        Defaults.publisher(.hideFromScreenRecording)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak window] _ in
                guard let window else { return }
                apply(to: window)
            }
            .store(in: &bag)
    }
}
