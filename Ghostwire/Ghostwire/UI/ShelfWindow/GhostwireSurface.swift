//
//  GhostwireSurface.swift
//  Ghostwire
//
//  GW-223. Which surface a shared tab view (AgentsTabView / NotchHomeView) is
//  rendering on. The notch and the detached window reuse the SAME tab views, but
//  the notch bakes in collapse behaviour — chiefly `.blur(... notchState == .closed)`,
//  which hides content as the panel shrinks. In a real window there is no
//  collapse, so that blur (and the notch's scroll-gesture suppression) must be
//  switched off. This flag carries that distinction through the environment.
//
//  Defaults to `.notch`, so every existing call site is unchanged; only the
//  window opts into `.window`.
//

import SwiftUI

enum GhostwireSurface {
    /// Rendered inside the notch panel (collapse blur / suppression active).
    case notch
    /// Rendered inside the detached Ghostwire window (no collapse, no blur).
    case window
}

private struct GhostwireSurfaceKey: EnvironmentKey {
    static let defaultValue: GhostwireSurface = .notch
}

extension EnvironmentValues {
    var ghostwireSurface: GhostwireSurface {
        get { self[GhostwireSurfaceKey.self] }
        set { self[GhostwireSurfaceKey.self] = newValue }
    }
}
