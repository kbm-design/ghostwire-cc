//
//  ShelfContextProvider.swift
//  Ghostwire
//
//  GW-173: read-only view of the Shelf hold-store for the MCP serve side
//  (the PULL direction — agents pull held context out; symmetric with the
//  GW-219 client that consumes external servers).
//
//  WHY THIS IS NONISOLATED (and doesn't reuse ShelfStateViewModel/ShelfItem):
//   - The `mcp-serve` subcommand runs in a SEPARATE, headless process with no
//     main run loop, so it must not depend on the GUI's @MainActor world —
//     hopping to @MainActor there hangs (the main-actor executor isn't drained
//     without an app/RunLoop). So this reads the persisted store directly on a
//     background executor, reusing the shared, nonisolated `ShelfItemKind` and
//     `Bookmark` types.
//   - READ ONLY. Loads from `ShelfPersistenceService.storeURL`; never writes
//     (we deliberately avoid `ShelfStateViewModel.shared`, whose init/didSet
//     would re-save the file). Fresh read each call, so agents see live state.
//

import Foundation
import UniformTypeIdentifiers

/// Nonisolated decode of one persisted Shelf item. Matches the on-disk shape of
/// the @MainActor `ShelfItem` (same keys: id, kind, isTemporary) and reuses the
/// real `ShelfItemKind`, so it stays in lockstep with the writer.
struct ShelfStoredItem: Codable, Sendable, Equatable {
    let id: UUID
    var kind: ShelfItemKind
    var isTemporary: Bool

    init(id: UUID = UUID(), kind: ShelfItemKind, isTemporary: Bool = false) {
        self.id = id
        self.kind = kind
        self.isTemporary = isTemporary
    }
}

/// One Shelf item, flattened for MCP listings.
struct HeldItemSnapshot: Sendable, Codable, Equatable {
    enum Kind: String, Sendable, Codable { case file, text, link }

    let id: String
    let kind: Kind
    let displayName: String
    /// Shelf insertion index (0 = oldest). The model carries no real save
    /// timestamp, so position is the recency signal; for files we add the
    /// filesystem `modifiedAt`. Listings come newest-first.
    let position: Int
    let isTemporary: Bool

    var path: String?
    var byteSize: Int?
    var modifiedAt: String?  // ISO-8601, filesystem mtime
    var mimeType: String?
}

/// A single resolved item for `get_file`: a path for filesystem-capable agents
/// plus inline content for sandboxed consumers (when textual and within the cap).
struct ResolvedShelfItem: Sendable, Codable, Equatable {
    let id: String
    let kind: HeldItemSnapshot.Kind
    let displayName: String
    var path: String?
    var content: String?
    var mimeType: String?
    var byteSize: Int?
    var contentOmitted: Bool
    var note: String?
}

struct ShelfContextProvider: Sendable {
    /// Inline content cap for `get_file`. Larger/binary files return a path only.
    static let maxInlineBytes = 1_000_000

    private let loadItems: @Sendable () -> [ShelfStoredItem]

    /// Production: read-only load from the on-disk Shelf store.
    init() {
        self.loadItems = { Self.loadFromDisk() }
    }

    /// Test seam: inject a fixed item list.
    init(items: [ShelfStoredItem]) {
        self.loadItems = { items }
    }

    // MARK: - Listings

    /// Held items, newest first. Transient items are excluded unless requested.
    func heldItems(includeTemporary: Bool = false) -> [HeldItemSnapshot] {
        var out: [HeldItemSnapshot] = []
        for (index, item) in loadItems().enumerated() {
            if item.isTemporary && !includeTemporary { continue }
            out.append(snapshot(of: item, position: index))
        }
        return out.reversed()
    }

    /// Substring/keyword match over display name and file path. Case-insensitive;
    /// empty query returns the full listing.
    func search(_ query: String, includeTemporary: Bool = false) -> [HeldItemSnapshot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = heldItems(includeTemporary: includeTemporary)
        guard !needle.isEmpty else { return all }
        return all.filter { snap in
            if snap.displayName.lowercased().contains(needle) { return true }
            if let path = snap.path, path.lowercased().contains(needle) { return true }
            return false
        }
    }

    // MARK: - Resolution

    /// Resolve one item by id into a path and/or inline content.
    func resolve(id: String) -> ResolvedShelfItem? {
        guard let item = loadItems().first(where: { $0.id.uuidString == id }) else {
            return nil
        }
        switch item.kind {
        case .text(let string):
            return ResolvedShelfItem(
                id: id, kind: .text, displayName: Self.displayName(for: item.kind),
                path: nil, content: string, mimeType: "text/plain",
                byteSize: string.utf8.count, contentOmitted: false, note: nil)
        case .link(let url):
            return ResolvedShelfItem(
                id: id, kind: .link, displayName: Self.displayName(for: item.kind),
                path: nil, content: url.absoluteString, mimeType: nil,
                byteSize: nil, contentOmitted: false, note: nil)
        case .file(let bookmarkData):
            return resolveFile(
                id: id, displayName: Self.displayName(for: item.kind), bookmarkData: bookmarkData)
        }
    }

    // MARK: - Loading

    private static func loadFromDisk() -> [ShelfStoredItem] {
        guard let data = try? Data(contentsOf: ShelfPersistenceService.storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let items = try? decoder.decode([ShelfStoredItem].self, from: data) {
            return items
        }
        // Tolerate a partially-corrupt array: keep the items that decode.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(ShelfStoredItem.self, from: elementData)
        }
    }

    // MARK: - Snapshot + file resolution

    private func snapshot(of item: ShelfStoredItem, position: Int) -> HeldItemSnapshot {
        let name = Self.displayName(for: item.kind)
        switch item.kind {
        case .text:
            return HeldItemSnapshot(
                id: item.id.uuidString, kind: .text, displayName: name,
                position: position, isTemporary: item.isTemporary)
        case .link:
            return HeldItemSnapshot(
                id: item.id.uuidString, kind: .link, displayName: name,
                position: position, isTemporary: item.isTemporary)
        case .file(let bookmarkData):
            var snap = HeldItemSnapshot(
                id: item.id.uuidString, kind: .file, displayName: name,
                position: position, isTemporary: item.isTemporary)
            if let url = Bookmark(data: bookmarkData).resolveURL() {
                snap.path = url.path
                snap.mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                snap.byteSize = values?.fileSize
                if let mtime = values?.contentModificationDate {
                    snap.modifiedAt = Self.iso8601.string(from: mtime)
                }
            }
            return snap
        }
    }

    private func resolveFile(id: String, displayName: String, bookmarkData: Data) -> ResolvedShelfItem {
        let bookmark = Bookmark(data: bookmarkData)
        guard let url = bookmark.resolveURL() else {
            return ResolvedShelfItem(
                id: id, kind: .file, displayName: displayName, path: nil, content: nil,
                mimeType: nil, byteSize: nil, contentOmitted: true,
                note: "File is no longer available (the bookmark could not be resolved).")
        }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType

        let read: (path: String, content: String?, size: Int?, omitted: Bool, note: String?)? =
            bookmark.withAccess { resolved -> (String, String?, Int?, Bool, String?) in
                let path = resolved.path
                let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let size, size > Self.maxInlineBytes {
                    return (path, nil, size, true,
                        "File exceeds the \(Self.maxInlineBytes / 1_000_000) MB inline cap — read it from `path`.")
                }
                if let data = try? Data(contentsOf: resolved),
                    let text = String(data: data, encoding: .utf8) {
                    return (path, text, data.count, false, nil)
                }
                return (path, nil, size, true, "Binary or non-UTF-8 file — read it from `path`.")
            }

        guard let read else {
            return ResolvedShelfItem(
                id: id, kind: .file, displayName: displayName, path: url.path, content: nil,
                mimeType: mimeType, byteSize: nil, contentOmitted: true,
                note: "File could not be read.")
        }
        return ResolvedShelfItem(
            id: id, kind: .file, displayName: displayName, path: read.path, content: read.content,
            mimeType: mimeType, byteSize: read.size, contentOmitted: read.omitted, note: read.note)
    }

    // MARK: - Display name (nonisolated projection of ShelfItem.displayName)

    static func displayName(for kind: ShelfItemKind) -> String {
        switch kind {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .link(let url):
            let s = url.absoluteString
            if s.hasPrefix("https://") { return String(s.dropFirst("https://".count)) }
            if s.hasPrefix("http://") { return String(s.dropFirst("http://".count)) }
            return s
        case .file(let bookmarkData):
            guard let url = Bookmark(data: bookmarkData).resolveURL() else { return "" }
            if url.pathExtension.lowercased() == "json" && url.path.contains("TextBlocks") {
                if let name = textBlockTitle(at: url) { return name }
            } else if url.pathExtension.lowercased() == "webloc" && url.path.contains("WebLocs") {
                if let name = weblocTitle(at: url) { return name }
            }
            return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? url.lastPathComponent
        }
    }

    private static func textBlockTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct TextBlockData: Codable {
            let content: String
            let title: String?
            var displayTitle: String {
                if let title, !title.isEmpty { return title }
                let firstLine = content.components(separatedBy: .newlines).first ?? content
                return firstLine.count > 50 ? String(firstLine.prefix(47)) + "..." : firstLine
            }
        }
        return (try? decoder.decode(TextBlockData.self, from: data))?.displayTitle
    }

    private static func weblocTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let urlString = plist["URL"] as? String
        else { return nil }
        return (plist["Title"] as? String) ?? urlString
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
