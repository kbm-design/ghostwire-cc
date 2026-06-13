//
//  ShelfContextProviderTests.swift
//  GhostwireTests
//
//  GW-173: the read-only Shelf view that backs the MCP serve side.
//

import XCTest

@testable import Ghostwire

final class ShelfContextProviderTests: XCTestCase {

    private func tempTextFile(_ contents: String, ext: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw173-\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHeldItemsReturnsNewestFirstAndExcludesTemporary() {
        let a = ShelfStoredItem(kind: .text(string: "first"))
        let b = ShelfStoredItem(kind: .link(url: URL(string: "https://example.com/page")!))
        let temp = ShelfStoredItem(kind: .text(string: "transient"), isTemporary: true)
        let provider = ShelfContextProvider(items: [a, b, temp])

        let items = provider.heldItems()
        XCTAssertEqual(items.map(\.id), [b.id.uuidString, a.id.uuidString])  // newest first
        XCTAssertFalse(items.contains { $0.kind == .text && $0.displayName == "transient" })

        let withTemp = provider.heldItems(includeTemporary: true)
        XCTAssertEqual(withTemp.count, 3)
    }

    func testSearchMatchesDisplayNameCaseInsensitively() {
        let a = ShelfStoredItem(kind: .text(string: "Quarterly Roadmap notes"))
        let b = ShelfStoredItem(kind: .link(url: URL(string: "https://example.com/budget")!))
        let provider = ShelfContextProvider(items: [a, b])

        XCTAssertEqual(provider.search("roadmap").map(\.id), [a.id.uuidString])
        XCTAssertEqual(provider.search("BUDGET").map(\.id), [b.id.uuidString])
        XCTAssertEqual(provider.search("").count, 2)  // empty query => full listing
        XCTAssertTrue(provider.search("nothing-here").isEmpty)
    }

    func testResolveTextReturnsInlineContent() {
        let item = ShelfStoredItem(kind: .text(string: "hello world"))
        let provider = ShelfContextProvider(items: [item])

        let resolved = provider.resolve(id: item.id.uuidString)
        XCTAssertEqual(resolved?.kind, .text)
        XCTAssertEqual(resolved?.content, "hello world")
        XCTAssertNil(resolved?.path)
        XCTAssertEqual(resolved?.contentOmitted, false)
    }

    func testResolveLinkReturnsURLInline() {
        let url = URL(string: "https://example.com/path?q=1")!
        let item = ShelfStoredItem(kind: .link(url: url))
        let provider = ShelfContextProvider(items: [item])

        let resolved = provider.resolve(id: item.id.uuidString)
        XCTAssertEqual(resolved?.kind, .link)
        XCTAssertEqual(resolved?.content, url.absoluteString)
    }

    func testResolveFileReturnsPathAndInlineTextContent() throws {
        let fileURL = try tempTextFile("file body contents")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bookmark = try Bookmark(url: fileURL)
        let item = ShelfStoredItem(kind: .file(bookmark: bookmark.data))
        let provider = ShelfContextProvider(items: [item])

        let resolved = provider.resolve(id: item.id.uuidString)
        XCTAssertEqual(resolved?.kind, .file)
        // Bookmark resolution canonicalizes symlinks (/var -> /private/var).
        XCTAssertEqual(
            resolved.flatMap { $0.path }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            fileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved?.content, "file body contents")
        XCTAssertEqual(resolved?.contentOmitted, false)
    }

    func testHeldItemsCarriesFilePathMetadata() throws {
        let fileURL = try tempTextFile("x")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let item = ShelfStoredItem(kind: .file(bookmark: try Bookmark(url: fileURL).data))
        let provider = ShelfContextProvider(items: [item])

        let snap = provider.heldItems().first
        XCTAssertEqual(snap?.kind, .file)
        XCTAssertEqual(
            snap.flatMap { $0.path }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            fileURL.resolvingSymlinksInPath().path)
        XCTAssertNotNil(snap?.modifiedAt)
    }

    func testResolveUnknownIdReturnsNil() {
        let provider = ShelfContextProvider(items: [])
        XCTAssertNil(provider.resolve(id: UUID().uuidString))
    }
}
