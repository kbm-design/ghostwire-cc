//
//  AppCategory.swift
//  Ghostwire
//
//  GW-182 — the join key. The ambient spine (GW-172) records bundle IDs; a feed
//  Source declares which categories it speaks to. This is what makes the two
//  comparable.
//
//  Apps classify THEMSELVES: `LSApplicationCategoryType` in the app's own
//  Info.plist. On a typical Mac ~85% of installed apps declare one, and they're
//  right where it matters — Xcode/Cursor/VSCode/Ghostty/Warp all say
//  `developer-tools`, TradingView says `finance`, Figma says `graphics-design`.
//  So there is no bundled list of app IDs to maintain, and an app the user
//  installs tomorrow classifies itself on arrival.
//
//  An app that declares nothing gets `.other` — no affinity, no opinion, and the
//  feed simply stays in the user's order. That's the right outcome, not a gap:
//  ranking is opt-in (`FeedRankingMode.context`) and its whole discipline is
//  that being silent beats being confidently wrong.
//

import AppKit
import Foundation

/// The shared vocabulary both sides of the ranker project onto.
enum AppCategory: String, CaseIterable, Sendable, Codable {
    case coding
    case research
    case comms
    case design
    case finance
    case entertainment
    /// Unmapped or undeclared. Contributes nothing — never a match.
    case other
}

enum AppCategoryMap {

    /// Category for a running app, read from its own declared
    /// `LSApplicationCategoryType`. Cached — the answer can't change while the
    /// app is installed, and this is called on the app-switch path.
    static func category(for bundleID: String) -> AppCategory {
        guard !bundleID.isEmpty else { return .other }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[bundleID] { return cached }
        let resolved = category(forDeclaredType: declaredType(for: bundleID))
        cache[bundleID] = resolved
        return resolved
    }

    /// Pure: Apple's category constant → ours. Unmapped, absent, or one of the
    /// junk-drawer categories → `.other`.
    ///
    /// `productivity` and `utilities` are deliberately NOT mapped. They're the
    /// two largest buckets on a real Mac and hold everything from a browser to a
    /// menu-bar toggle, so they carry no usable signal — Safari declares
    /// `productivity`. Mapping them would manufacture confidence we don't have.
    static func category(forDeclaredType declared: String?) -> AppCategory {
        guard let declared else { return .other }
        let suffix = declared.hasPrefix(prefix)
            ? String(declared.dropFirst(prefix.count))
            : declared
        switch suffix {
        case "developer-tools":
            return .coding
        case "finance":
            return .finance
        case "graphics-design", "photography":
            return .design
        case "social-networking":
            return .comms
        case "news", "reference", "books", "education":
            return .research
        case "music", "video", "entertainment", "games", "board-games", "sports":
            return .entertainment
        default:
            // Includes productivity / utilities / business and anything Apple
            // adds later — unknown means no opinion.
            return .other
        }
    }

    /// Clear the cache (app installed/removed, or a test wants a clean slate).
    static func resetCache() {
        cacheLock.lock()
        cache = [:]
        cacheLock.unlock()
    }

    // MARK: - Lookup

    private static let prefix = "public.app-category."

    /// The app's declared category, or nil when it declares none / isn't found.
    private static func declaredType(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }

    private nonisolated(unsafe) static var cache: [String: AppCategory] = [:]
    private static let cacheLock = NSLock()
}
