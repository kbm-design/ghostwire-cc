//
//  SourceAppIcon.swift
//  Ghostwire
//
//  GW-221 source-attribution resolver, extracted so both the Shelf's unified
//  card footer and the GW-259 feed card footer resolve the same way (bundle id →
//  app icon) instead of each carrying a private copy.
//

import AppKit

/// The app icon for a source's bundle id, or nil if there's no bundle id or no
/// installed app matches. Callers fall back to a kind glyph when this is nil.
func sourceAppIcon(for bundleId: String?) -> NSImage? {
    guard let bundleId,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}
