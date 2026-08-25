//
//  UnifiedCard.swift
//  Ghostwire
//
//  GW-218 (Shelf surface v2). View-layer adapter that presents an item from
//  EITHER store as one card in the unified feed:
//    - `.saved`     -> a Shelf `ShelfItem` (persists; pinned/dragged; expiry-exempt)
//    - `.transient` -> a `ClipboardEntry` (rolling copies; auto-expiring)
//
//  Approach B (Keelan's call, 2026-06-06): we DON'T migrate storage. The two
//  stores stay separate; this type only unifies them for rendering + actions.
//  `UnifiedShelfViewModel` merges both into one ordered, de-duplicated feed.
//
//  The per-type rendering keys off `CardKind` (text/image/color/link/file),
//  modeled on the `ToolResultViews` dispatcher idiom rather than a parallel one.
//
//  GW-166: a transient entry the store has SEALED has no plaintext to adapt —
//  `rawText`/`previewText` are empty by construction, which is what keeps the
//  secret out of previews, tooltips, search and the send payload without a
//  single "if sensitive" scattered through the render path. `isSensitive` drives
//  the masked presentation; `sensitiveEntry` is the handle every gated action
//  passes to `SensitiveClipAccess`.
//

import AppKit
import Foundation

/// The five v1 preview types (icons/SVG + app-screenshot previews fast-follow).
enum CardKind: Equatable {
    case text
    case color
    case link
    case image
    case file
}

@MainActor
struct UnifiedCard: Identifiable {
    enum Source {
        /// Persists in the Shelf store; pin/drag put it here; exempt from auto-expiry.
        case saved(ShelfItem)
        /// Rolling clipboard history; auto-capture flood lands here; auto-expires.
        case transient(ClipboardEntry)
    }

    let source: Source

    /// Stable, store-scoped id — also used as the selection key for GW-213.
    var id: String {
        switch source {
        case .saved(let item): return "saved:\(item.id.uuidString)"
        case .transient(let entry): return "transient:\(entry.id.uuidString)"
        }
    }

    /// Pinned/saved items render a pin and never auto-expire.
    var isPinned: Bool {
        if case .saved = source { return true }
        return false
    }

    // MARK: - GW-166 sensitive clips

    /// True when this card's content is sealed behind Touch ID. Only transient
    /// (clipboard) cards can be sensitive — pinning a sealed clip is refused, so
    /// a sealed secret never reaches the Shelf's plaintext store.
    var isSensitive: Bool {
        if case .transient(let entry) = source { return entry.isSensitive }
        return false
    }

    /// Short shape label for the masked card ("API token", "Private key").
    var sensitiveLabel: String {
        if case .transient(let entry) = source, entry.isSensitive { return entry.sensitiveLabel }
        return "Sensitive"
    }

    /// The sealed entry behind this card — the handle for `SensitiveClipAccess`.
    /// Nil for anything that isn't a sealed clip, so a caller can't accidentally
    /// route a normal card through the auth gate (or vice versa).
    var sensitiveEntry: ClipboardEntry? {
        guard case .transient(let entry) = source, entry.isSensitive else { return nil }
        return entry
    }

    // MARK: - Derived classification

    var kind: CardKind {
        // A sealed clip has no text to classify — and must never be sniffed for
        // a colour/link shape, which would leak structure about the secret.
        if isSensitive { return .text }
        switch source {
        case .saved(let item):
            switch item.kind {
            case .text(let s):
                if HexColor.parse(s) != nil { return .color }
                return .text
            case .link:
                return .link
            case .file:
                return isImagePath(fileURL?.path) ? .image : .file
            }
        case .transient(let entry):
            switch entry.resolvedKind {
            case .text:
                let s = entry.content ?? ""
                if HexColor.parse(s) != nil { return .color }
                if looksLikeURL(s) { return .link }
                return .text
            case .file:
                return isImagePath(entry.path) ? .image : .file
            }
        }
    }

    // MARK: - Derived content

    /// One-line preview text (first line for text, last path component for files,
    /// host for links, hex for colors).
    var previewText: String {
        switch kind {
        case .color:
            return colorHex ?? rawText
        case .link:
            return linkURL.map { friendlyHost($0) } ?? rawText
        case .image, .file:
            return (filePath as NSString?)?.lastPathComponent ?? displayName
        case .text:
            let body = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.components(separatedBy: .newlines).first ?? body
        }
    }

    /// Full raw text payload (text/color/link kinds), else the display name.
    var rawText: String {
        switch source {
        case .saved(let item):
            switch item.kind {
            case .text(let s): return s
            case .link(let url): return url.absoluteString
            case .file: return item.displayName
            }
        case .transient(let entry):
            // Sealed: `content` is nil, so this is "" — the property that keeps
            // the secret out of previews, tooltips, search and sends.
            return entry.content ?? entry.path ?? ""
        }
    }

    var displayName: String {
        switch source {
        case .saved(let item): return item.displayName
        case .transient(let entry):
            switch entry.resolvedKind {
            case .file: return (entry.path as NSString?)?.lastPathComponent ?? (entry.path ?? "")
            case .text: return previewText
            }
        }
    }

    /// Resolved on-disk URL for file/image kinds (security-scoped for saved items).
    var fileURL: URL? {
        switch source {
        case .saved(let item):
            return item.fileURL
        case .transient(let entry):
            guard entry.resolvedKind == .file, let path = entry.path,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// Path string without resolving a bookmark — cheap, for previews/classification.
    private var filePath: String? {
        switch source {
        case .saved: return fileURL?.path
        case .transient(let entry): return entry.resolvedKind == .file ? entry.path : nil
        }
    }

    var linkURL: URL? {
        switch source {
        case .saved(let item):
            if case .link(let url) = item.kind { return url }
            return nil
        case .transient(let entry):
            guard entry.resolvedKind == .text, let s = entry.content else { return nil }
            return looksLikeURL(s) ? URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        }
    }

    var colorHex: String? {
        guard kind == .color else { return nil }
        return HexColor.normalizedHex(rawText)
    }

    var color: NSColor? {
        guard kind == .color else { return nil }
        return HexColor.parse(rawText)
    }

    /// Bundle id of the source app (transient only — saved items don't record it).
    var sourceBundleId: String? {
        if case .transient(let entry) = source { return entry.sourceBundleId }
        return nil
    }

    /// Capture time (transient only). Saved items have no `capturedAt` under
    /// Approach B; the feed VM supplies a synthetic recency for ordering.
    var date: Date? {
        if case .transient(let entry) = source { return entry.date }
        return nil
    }

    var isTruncatedText: Bool {
        if case .transient(let entry) = source { return entry.truncated }
        return false
    }

    // MARK: - Dedup + send

    /// Cross-store dedup key. Matches `ShelfItem.identityKey` so a copied-then-
    /// dragged (or pinned) file collapses to one card (saved wins in the VM).
    var identityKey: String {
        switch source {
        case .saved(let item):
            return item.identityKey
        case .transient(let entry):
            switch entry.resolvedKind {
            case .file:
                if let path = entry.path {
                    return "file://" + URL(fileURLWithPath: path).standardizedFileURL.path
                }
                return "file://missing/\(entry.id.uuidString)"
            case .text:
                // A sealed clip dedupes on its keyed fingerprint (there is no
                // plaintext to key on) and falls back to its own id so two
                // different secrets never collide on an empty string.
                if entry.isSensitive {
                    return "sensitive://" + (entry.fingerprint ?? entry.id.uuidString)
                }
                return "text://" + (entry.content ?? "")
            }
        }
    }

    /// The payload for `SendToAgentCoordinator` — text inline, file as `@path`.
    /// Returns nil when a file kind can't be resolved on disk, and always for a
    /// sealed clip: its payload only exists after `SensitiveClipAccess` has
    /// unlocked it, so `UnifiedShelfViewModel.send` builds that one itself.
    var sendPayload: SendToAgentCoordinator.Payload? {
        guard !isSensitive else { return nil }
        switch kind {
        case .text, .color:
            let s = rawText
            return s.isEmpty ? nil : .text(s)
        case .link:
            return .text(linkURL?.absoluteString ?? rawText)
        case .image, .file:
            guard let url = fileURL else { return nil }
            return .file(url)
        }
    }

    // MARK: - Helpers

    private func isImagePath(_ path: String?) -> Bool {
        guard let ext = path.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty else { return false }
        return Self.imageExtensions.contains(ext)
    }

    private func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: { $0 == "\n" || $0 == " " }) else { return false }
        return t.hasPrefix("https://") || t.hasPrefix("http://")
    }

    private func friendlyHost(_ url: URL) -> String {
        if let host = url.host { return host + (url.path.isEmpty || url.path == "/" ? "" : url.path) }
        return url.absoluteString
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg"
    ]
}

// MARK: - Hex color parsing (preview-only; cheap)

enum HexColor {
    /// Parse a standalone hex color string (`#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA`,
    /// `#` optional). Returns nil for anything that isn't a bare hex color so we
    /// don't mis-tag ordinary text as a swatch.
    static func parse(_ raw: String) -> NSColor? {
        guard let hex = normalizedHex(raw) else { return nil }
        let body = String(hex.dropFirst()) // strip '#'
        func channel(_ s: Substring) -> CGFloat { CGFloat(Int(s, radix: 16) ?? 0) / 255.0 }
        let chars = Array(body)
        switch chars.count {
        case 3, 4:
            // Expand shorthand (#RGB -> #RRGGBB)
            let expanded = chars.map { "\($0)\($0)" }.joined()
            return parse("#" + expanded)
        case 6:
            let r = channel(body.prefix(2))
            let g = channel(body.dropFirst(2).prefix(2))
            let b = channel(body.dropFirst(4).prefix(2))
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = channel(body.prefix(2))
            let g = channel(body.dropFirst(2).prefix(2))
            let b = channel(body.dropFirst(4).prefix(2))
            let a = channel(body.dropFirst(6).prefix(2))
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        default:
            return nil
        }
    }

    /// Normalize to an uppercased `#`-prefixed hex string if `raw` is a bare hex
    /// color, else nil.
    static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.contains(where: { $0 == "\n" || $0 == " " }) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard [3, 4, 6, 8].contains(s.count) else { return nil }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s.uppercased()
    }
}
