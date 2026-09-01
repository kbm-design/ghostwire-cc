//
//  ClipboardHistoryStoreTests.swift
//  GhostwireTests
//
//  GW-210: clipboard-history store pruning + dedupe + persistence/migration,
//  and the pure capture seam (privacy gates + text cap). AlertHistoryStore
//  test style — pure helpers exercised directly, persistence over a temp file.
//

import Defaults
import XCTest
@testable import Ghostwire

final class ClipboardHistoryStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func entry(ageSeconds: TimeInterval, content: String = "x") -> ClipboardEntry {
        ClipboardEntry(
            id: UUID(),
            date: now.addingTimeInterval(-ageSeconds),
            kind: .text,
            content: content
        )
    }

    func testDropsEntriesOlderThanMaxAge() {
        let fresh = entry(ageSeconds: 3_600)
        let stale = entry(ageSeconds: 8 * 86_400)

        let result = ClipboardHistoryStore.pruned(
            [stale, fresh], maxEntries: 100, maxAge: 7 * 86_400, now: now
        )

        XCTAssertEqual(result, [fresh])
    }

    func testCapsToNewestMaxEntries() {
        let entries = (0..<5).map { entry(ageSeconds: TimeInterval(100 - $0)) }

        let result = ClipboardHistoryStore.pruned(
            entries, maxEntries: 3, maxAge: 7 * 86_400, now: now
        )

        XCTAssertEqual(result, Array(entries.suffix(3)))
    }

    func testSortsOldestFirst() {
        let older = entry(ageSeconds: 500)
        let newer = entry(ageSeconds: 5)

        let result = ClipboardHistoryStore.pruned(
            [newer, older], maxEntries: 100, maxAge: 86_400, now: now
        )

        XCTAssertEqual(result, [older, newer])
    }

    func testZeroOrNegativeMaxEntriesYieldsEmpty() {
        let entries = [entry(ageSeconds: 10)]
        XCTAssertTrue(ClipboardHistoryStore.pruned(entries, maxEntries: 0, maxAge: 86_400, now: now).isEmpty)
        XCTAssertTrue(ClipboardHistoryStore.pruned(entries, maxEntries: -1, maxAge: 86_400, now: now).isEmpty)
    }
}

// MARK: - Dedupe + persistence (MainActor store)

@MainActor
final class ClipboardHistoryStorePersistenceTests: XCTestCase {

    private var tempURL: URL!
    private var savedMaxEntries: Int!
    private var savedMaxAgeDays: Int!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("clipboard-history.json")
        savedMaxEntries = Defaults[.clipboardHistoryMaxEntries]
        savedMaxAgeDays = Defaults[.clipboardHistoryMaxAgeDays]
    }

    override func tearDown() {
        Defaults[.clipboardHistoryMaxEntries] = savedMaxEntries
        Defaults[.clipboardHistoryMaxAgeDays] = savedMaxAgeDays
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    /// v-none migration: a fresh store with no file on disk starts empty and
    /// doesn't crash (synthesized Codable + decodeIfPresent on optionals).
    func testFreshStoreIsEmpty() {
        let store = ClipboardHistoryStore(fileURL: tempURL)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testConsecutiveIdenticalDedupesAndUpdatesTimestamp() {
        let store = ClipboardHistoryStore(fileURL: tempURL)
        store.record(ClipboardEntry(kind: .text, content: "hello"))
        let firstDate = store.entries.last?.date
        // Same content again → no insert, timestamp refreshed.
        store.record(ClipboardEntry(kind: .text, content: "hello"))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertNotEqual(store.entries.last?.date, firstDate)
    }

    func testNonConsecutiveIdenticalIsNotDeduped() {
        let store = ClipboardHistoryStore(fileURL: tempURL)
        store.record(ClipboardEntry(kind: .text, content: "a"))
        store.record(ClipboardEntry(kind: .text, content: "b"))
        store.record(ClipboardEntry(kind: .text, content: "a"))

        XCTAssertEqual(store.entries.count, 3)
    }

    func testFileAndTextSameValueAreNotDeduped() {
        let store = ClipboardHistoryStore(fileURL: tempURL)
        store.record(ClipboardEntry(kind: .text, content: "/tmp/x"))
        store.record(ClipboardEntry(kind: .file, path: "/tmp/x"))
        XCTAssertEqual(store.entries.count, 2)
    }

    func testRecordPersistsAcrossReload() throws {
        Defaults[.clipboardHistoryMaxEntries] = 25
        Defaults[.clipboardHistoryMaxAgeDays] = 7
        let store = ClipboardHistoryStore(fileURL: tempURL)
        store.record(ClipboardEntry(kind: .text, content: "persist-me"))
        ClipboardHistoryStore.ioQueue.sync {}

        let reloaded = ClipboardHistoryStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.content, "persist-me")
    }

    func testLoadWritesEnforcedAgeCapBackToDisk() throws {
        Defaults[.clipboardHistoryMaxEntries] = 25
        Defaults[.clipboardHistoryMaxAgeDays] = 7
        let store = ClipboardHistoryStore(fileURL: tempURL)
        // Two stale (8d) + one fresh; age prune drops the stale ones.
        let stale = Date().addingTimeInterval(-8 * 86_400)
        store.record(ClipboardEntry(date: stale, kind: .text, content: "old1"))
        store.record(ClipboardEntry(date: stale, kind: .text, content: "old2"))
        store.record(ClipboardEntry(kind: .text, content: "new"))
        ClipboardHistoryStore.ioQueue.sync {}

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.content, "new")
    }
}

// MARK: - Capture seam (privacy gates + cap)
//
// GW-166 added `protectCredentials` to this seam. These cases are about the
// GW-210 rules, so they pass `false` — credential detection has its own suite
// (SensitiveCaptureTests / CredentialShapeDetectorTests).

final class ClipboardCaptureTests: XCTestCase {

    private func snapshot(
        types: [String] = ["public.utf8-plain-text"],
        string: String? = "copied text",
        filePath: String? = nil
    ) -> ClipboardSnapshot {
        ClipboardSnapshot(types: types, string: string, filePath: filePath, sourceBundleId: "com.test")
    }

    func testCapturesPlainText() {
        let entry = ClipboardCapture.entry(from: snapshot(), maxTextBytes: 1024, protectCredentials: false)
        XCTAssertEqual(entry?.resolvedKind, .text)
        XCTAssertEqual(entry?.content, "copied text")
        XCTAssertEqual(entry?.truncated, false)
    }

    func testSkipsConcealedType() {
        let s = snapshot(types: ["public.utf8-plain-text", ClipboardSnapshot.concealedType])
        XCTAssertNil(ClipboardCapture.entry(from: s, maxTextBytes: 1024, protectCredentials: false))
    }

    func testSkipsTransientType() {
        let s = snapshot(types: ["public.utf8-plain-text", ClipboardSnapshot.transientType])
        XCTAssertNil(ClipboardCapture.entry(from: s, maxTextBytes: 1024, protectCredentials: false))
    }

    func testSkipsOwnWrite() {
        let s = snapshot(types: ["public.utf8-plain-text", ClipboardSnapshot.ghostwireMarkerType])
        XCTAssertNil(ClipboardCapture.entry(from: s, maxTextBytes: 1024, protectCredentials: false))
    }

    func testSkipsEmptyAndWhitespaceText() {
        XCTAssertNil(ClipboardCapture.entry(from: snapshot(string: ""), maxTextBytes: 1024, protectCredentials: false))
        XCTAssertNil(ClipboardCapture.entry(from: snapshot(string: "   \n\t"), maxTextBytes: 1024, protectCredentials: false))
    }

    func testCapturesFilePathPreferredOverText() {
        let s = snapshot(types: ["public.file-url"], string: "/Users/x/a.txt", filePath: "/Users/x/a.txt")
        let entry = ClipboardCapture.entry(from: s, maxTextBytes: 1024, protectCredentials: false)
        XCTAssertEqual(entry?.resolvedKind, .file)
        XCTAssertEqual(entry?.path, "/Users/x/a.txt")
    }

    func testTruncatesOversizeTextAndFlags() {
        let big = String(repeating: "a", count: 200)
        let entry = ClipboardCapture.entry(from: snapshot(string: big), maxTextBytes: 100, protectCredentials: false)
        XCTAssertEqual(entry?.truncated, true)
        XCTAssertEqual(entry?.content?.utf8.count, 100)
    }

    func testCapNeverSplitsMultibyteCharacters() {
        // Each emoji is 4 UTF-8 bytes; cap at 6 must keep exactly one (4 bytes),
        // never half of the second.
        let (capped, truncated) = ClipboardCapture.cap("😀😀😀", maxBytes: 6)
        XCTAssertEqual(capped, "😀")
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(capped.utf8.count, 6)
    }
}
