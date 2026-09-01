//
//  SensitiveClipboardTests.swift
//  GhostwireTests
//
//  GW-166: the half of credential protection that isn't detection — sealing at
//  rest, the Touch ID gate, and the promises the UI relies on (masked previews,
//  no search, no pinning).
//
//  TEST SAFETY, deliberately layered:
//   • Every store here is built with `InMemoryClipboardKeyStore`, so no test
//     creates or reads the user's real Keychain item…
//   • …and `KeychainClipboardKeyStore` refuses under XCTest anyway, so a future
//     test that forgets fails closed instead of touching it.
//   • Auth is `StubAuthenticator`; `DeviceOwnerAuthenticator` also hard-refuses
//     under XCTest, so nothing can raise a Touch ID sheet and hang the suite.
//   • Stores use a temp file and injected `Limits`, so neither the user's
//     clipboard history nor their defaults domain is read or written.
//

import CryptoKit
import XCTest
@testable import Ghostwire

// MARK: - Sealing (pure)

final class ClipboardSealerTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)

    func testRoundTrip() {
        let secret = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        let box = ClipboardSealer.seal(secret, key: key)
        XCTAssertNotNil(box)
        XCTAssertEqual(ClipboardSealer.open(box!, key: key), secret)
    }

    func testCiphertextDoesNotContainThePlaintext() {
        let secret = "hunter2hunter2hunter2"
        let box = ClipboardSealer.seal(secret, key: key)!
        XCTAssertFalse(box.range(of: Data(secret.utf8)) != nil, "sealed box leaks the plaintext")
    }

    func testWrongKeyDoesNotOpen() {
        let box = ClipboardSealer.seal("secret", key: key)!
        XCTAssertNil(ClipboardSealer.open(box, key: SymmetricKey(size: .bits256)))
    }

    func testTamperedBoxDoesNotOpen() {
        var box = ClipboardSealer.seal("secret", key: key)!
        box[box.count - 1] ^= 0xFF // flip a bit in the GCM tag
        XCTAssertNil(ClipboardSealer.open(box, key: key))
    }

    func testGarbageDoesNotOpen() {
        XCTAssertNil(ClipboardSealer.open(Data([0x00, 0x01, 0x02]), key: key))
    }

    /// GCM re-nonces every seal, which is exactly why dedupe needs a fingerprint.
    func testTwoSealsOfTheSamePlaintextDiffer() {
        XCTAssertNotEqual(ClipboardSealer.seal("same", key: key), ClipboardSealer.seal("same", key: key))
    }

    func testFingerprintIsStablePerKeyAndDiffersAcrossKeys() {
        let a = ClipboardSealer.fingerprint("same", key: key)
        XCTAssertEqual(a, ClipboardSealer.fingerprint("same", key: key))
        XCTAssertNotEqual(a, ClipboardSealer.fingerprint("different", key: key))
        XCTAssertNotEqual(a, ClipboardSealer.fingerprint("same", key: SymmetricKey(size: .bits256)))
    }

    /// The whole point of keying it: the stored fingerprint must not be a
    /// brute-force oracle for a low-entropy secret.
    func testFingerprintIsNotAPlainDigest() {
        let plaintext = "hunter2"
        let bare = SHA256.hash(data: Data(plaintext.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(ClipboardSealer.fingerprint(plaintext, key: key), String(bare.prefix(32)))
    }
}

// MARK: - Key store seams

final class ClipboardKeyStoreTests: XCTestCase {

    func testInMemoryStoreIsStable() {
        let store = InMemoryClipboardKeyStore()
        let first = store.loadOrCreateKey()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, store.loadOrCreateKey())
    }

    /// The guard that keeps the suite off the user's real Keychain.
    func testKeychainStoreRefusesUnderXCTest() {
        XCTAssertNil(KeychainClipboardKeyStore.shared.loadOrCreateKey())
    }
}

// MARK: - Capture-side flagging

final class SensitiveCaptureTests: XCTestCase {

    private func snapshot(_ string: String) -> ClipboardSnapshot {
        ClipboardSnapshot(types: ["public.utf8-plain-text"], string: string, filePath: nil, sourceBundleId: "com.test")
    }

    private func entry(_ string: String, protect: Bool = true) -> ClipboardEntry? {
        ClipboardCapture.entry(from: snapshot(string), maxTextBytes: 100 * 1024, protectCredentials: protect)
    }

    func testCredentialShapedTextIsFlaggedWithItsShape() {
        let e = entry("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8")
        XCTAssertEqual(e?.isSensitive, true)
        XCTAssertEqual(e?.credentialShape, .tokenPrefix)
        XCTAssertEqual(e?.sensitiveLabel, CredentialShape.tokenPrefix.label)
    }

    func testOrdinaryTextIsNotFlagged() {
        let e = entry("just some copied prose")
        XCTAssertEqual(e?.isSensitive, false)
        XCTAssertNil(e?.sensitiveShape)
    }

    /// The settings toggle: off means no NEW detection.
    func testProtectionOffSkipsDetection() {
        let e = entry("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", protect: false)
        XCTAssertEqual(e?.isSensitive, false)
    }

    /// Capture flags but never seals — the store owns the ciphertext.
    func testCaptureLeavesTheEntryUnsealed() {
        let e = entry("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8")
        XCTAssertNil(e?.sealed)
        XCTAssertNotNil(e?.content)
    }

    /// Detection runs on the raw text, so a truncated key is still a key.
    func testDetectionRunsBeforeTheByteCap() {
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + String(repeating: "b3BlbnNzaC1r", count: 40)
        let e = ClipboardCapture.entry(from: snapshot(pem), maxTextBytes: 32, protectCredentials: true)
        XCTAssertEqual(e?.isSensitive, true)
        XCTAssertEqual(e?.credentialShape, .privateKey)
        XCTAssertEqual(e?.truncated, true)
    }

    /// GW-210's concealed/transient skip is untouched: a marked copy is still
    /// never captured at all, flagging or not.
    func testConcealedCopiesAreStillSkippedEntirely() {
        let concealed = ClipboardSnapshot(
            types: ["public.utf8-plain-text", ClipboardSnapshot.concealedType],
            string: "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
            filePath: nil,
            sourceBundleId: "com.test"
        )
        XCTAssertNil(ClipboardCapture.entry(from: concealed, maxTextBytes: 1024, protectCredentials: true))
    }
}

// MARK: - Store-side sealing

@MainActor
final class SensitiveClipboardStoreTests: XCTestCase {

    private var tempDir: URL!
    private var keyStore: InMemoryClipboardKeyStore!

    private static let secret = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw166-tests-\(UUID().uuidString)")
        keyStore = InMemoryClipboardKeyStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var fileURL: URL { tempDir.appendingPathComponent("clipboard-history.json") }

    /// Fixed limits, in-memory key: never reads the defaults domain or the
    /// Keychain, so the live app the test host is running stays untouched.
    private func makeStore(keyStore: ClipboardKeyStore? = nil) -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            fileURL: fileURL,
            keyStore: keyStore ?? self.keyStore,
            limits: .init(maxEntries: 100, maxAgeDays: 7)
        )
    }

    private func sensitiveEntry(_ content: String = secret) -> ClipboardEntry {
        ClipboardEntry(
            kind: .text,
            content: content,
            isSensitive: true,
            sensitiveShape: CredentialShape.tokenPrefix.rawValue
        )
    }

    func testRecordSealsAndDropsThePlaintext() throws {
        let store = makeStore()
        store.record(sensitiveEntry())

        let stored = try XCTUnwrap(store.entries.last)
        XCTAssertTrue(stored.isSensitive)
        XCTAssertNil(stored.content, "plaintext must not survive in memory")
        XCTAssertNotNil(stored.sealed)
        XCTAssertNotNil(stored.fingerprint)
    }

    func testPlaintextRoundTripsThroughTheStore() {
        let store = makeStore()
        store.record(sensitiveEntry())
        XCTAssertEqual(store.plaintext(of: store.entries.last!), Self.secret)
    }

    func testNonSensitiveEntriesAreUntouched() {
        let store = makeStore()
        store.record(ClipboardEntry(kind: .text, content: "ordinary"))
        XCTAssertEqual(store.entries.last?.content, "ordinary")
        XCTAssertNil(store.entries.last?.sealed)
        XCTAssertEqual(store.plaintext(of: store.entries.last!), "ordinary")
    }

    /// The one place we drop a clip instead of keeping it: with no key there is
    /// no safe way to hold it, and plaintext-on-disk is the bug being fixed.
    func testFailsClosedWhenNoKeyIsAvailable() {
        let store = makeStore(keyStore: UnavailableClipboardKeyStore())
        store.record(sensitiveEntry())
        XCTAssertTrue(store.entries.isEmpty, "a credential must never be stored in the clear")
    }

    func testSealedEntryPersistsAsCiphertextOnDisk() throws {
        let store = makeStore()
        store.record(sensitiveEntry())
        ClipboardHistoryStore.ioQueue.sync {}

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(Self.secret), "clipboard-history.json contains the plaintext secret")
        XCTAssertTrue(raw.contains("\"isSensitive\":true"))
        XCTAssertTrue(raw.contains("\"sealed\""))
    }

    func testSealedEntryReloadsAndStillDecrypts() throws {
        let store = makeStore()
        store.record(sensitiveEntry())
        ClipboardHistoryStore.ioQueue.sync {}

        // Same key store — a relaunch reads the same Keychain key.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.last?.isSensitive, true)
        XCTAssertEqual(reloaded.plaintext(of: reloaded.entries.last!), Self.secret)
    }

    /// A history file written before GW-166 has none of the new fields.
    func testPreGW166JSONStillLoads() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","date":"2026-08-01T10:00:00Z","kind":"text","content":"hello"}]
        """
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try legacy.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ClipboardHistoryStore(
            fileURL: fileURL,
            keyStore: keyStore,
            limits: .init(maxEntries: 100, maxAgeDays: 36_500)
        )
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.isSensitive, false)
        XCTAssertEqual(store.entries.first?.content, "hello")
    }

    /// Dedupe still works for sealed clips — via the keyed fingerprint, since
    /// two seals of the same plaintext are different bytes.
    func testConsecutiveIdenticalSecretsDedupe() {
        let store = makeStore()
        store.record(sensitiveEntry())
        store.record(sensitiveEntry())
        XCTAssertEqual(store.entries.count, 1)
    }

    func testDifferentSecretsDoNotDedupe() {
        let store = makeStore()
        store.record(sensitiveEntry())
        store.record(sensitiveEntry("sk-ant-api03-Zx9yW8vU7tS6rQ5pO4nM3lK2jI1h"))
        XCTAssertEqual(store.entries.count, 2)
    }

    /// A sealed clip and an ordinary one must never collapse into each other.
    func testSensitiveAndPlainDoNotDedupe() {
        let store = makeStore()
        store.record(ClipboardEntry(kind: .text, content: Self.secret))
        store.record(sensitiveEntry())
        XCTAssertEqual(store.entries.count, 2)
    }

    func testMarkNotSensitiveRestoresPlaintext() {
        let store = makeStore()
        store.record(sensitiveEntry())
        XCTAssertTrue(store.markNotSensitive(store.entries.last!))

        let updated = store.entries.last!
        XCTAssertFalse(updated.isSensitive)
        XCTAssertEqual(updated.content, Self.secret)
        XCTAssertNil(updated.sealed)
        XCTAssertNil(updated.fingerprint)
        XCTAssertNil(updated.sensitiveShape)
    }

    func testMarkNotSensitiveIsANoOpOnAPlainEntry() {
        let store = makeStore()
        store.record(ClipboardEntry(kind: .text, content: "ordinary"))
        XCTAssertFalse(store.markNotSensitive(store.entries.last!))
    }

    /// An unknown shape rawValue (written by a newer build) still reads as
    /// sensitive — it just loses the specific label.
    func testUnknownShapeStillReadsAsSensitive() {
        let entry = ClipboardEntry(kind: .text, content: "x", isSensitive: true, sensitiveShape: "quantumHash")
        XCTAssertTrue(entry.isSensitive)
        XCTAssertNil(entry.credentialShape)
        XCTAssertEqual(entry.sensitiveLabel, "Sensitive")
    }
}

// MARK: - The Touch ID gate

@MainActor
final class SensitiveClipAccessTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gw166-access-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeStore() -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            fileURL: tempDir.appendingPathComponent("clipboard-history.json"),
            keyStore: InMemoryClipboardKeyStore(),
            limits: .init(maxEntries: 100, maxAgeDays: 7)
        )
    }

    private func seeded(_ store: ClipboardHistoryStore) -> ClipboardEntry {
        store.record(ClipboardEntry(
            kind: .text,
            content: "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8",
            isSensitive: true,
            sensitiveShape: CredentialShape.tokenPrefix.rawValue
        ))
        return store.entries.last!
    }

    func testSuccessfulAuthYieldsPlaintext() async {
        let store = makeStore()
        let entry = seeded(store)
        let access = SensitiveClipAccess(authenticator: StubAuthenticator(result: true), store: store)

        let plain = await access.plaintext(for: entry, reason: "test")
        XCTAssertEqual(plain, "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8")
    }

    func testFailedAuthYieldsNothing() async {
        let store = makeStore()
        let entry = seeded(store)
        let access = SensitiveClipAccess(authenticator: StubAuthenticator(result: false), store: store)

        let plain = await access.plaintext(for: entry, reason: "test")
        XCTAssertNil(plain, "a cancelled prompt must not hand back the secret")
        XCTAssertFalse(access.isUnlocked(entry.id), "a failed prompt must not open the grace window")
    }

    func testPlainEntriesBypassTheGateEntirely() async {
        let store = makeStore()
        store.record(ClipboardEntry(kind: .text, content: "ordinary"))
        let auth = StubAuthenticator(result: false)
        let access = SensitiveClipAccess(authenticator: auth, store: store)

        let plain = await access.plaintext(for: store.entries.last!, reason: "test")
        XCTAssertEqual(plain, "ordinary")
        XCTAssertEqual(auth.callCount, 0, "an ordinary clip must never prompt")
    }

    /// The grace window: one prompt covers "reveal, then copy".
    func testSecondActionInsideTheGraceWindowDoesNotPromptAgain() async {
        let store = makeStore()
        let entry = seeded(store)
        let auth = StubAuthenticator(result: true)
        let access = SensitiveClipAccess(authenticator: auth, store: store)

        _ = await access.plaintext(for: entry, reason: "reveal")
        _ = await access.plaintext(for: entry, reason: "copy")
        XCTAssertEqual(auth.callCount, 1)
    }

    func testGraceWindowIsPerEntry() async {
        let store = makeStore()
        let first = seeded(store)
        store.record(ClipboardEntry(
            kind: .text,
            content: "sk-ant-api03-Zx9yW8vU7tS6rQ5pO4nM3lK2jI1h",
            isSensitive: true,
            sensitiveShape: CredentialShape.tokenPrefix.rawValue
        ))
        let second = store.entries.last!
        let auth = StubAuthenticator(result: true)
        let access = SensitiveClipAccess(authenticator: auth, store: store)

        _ = await access.plaintext(for: first, reason: "copy")
        _ = await access.plaintext(for: second, reason: "copy")
        XCTAssertEqual(auth.callCount, 2, "unlocking one clip must not unlock another")
    }

    func testGraceWindowExpires() {
        let access = SensitiveClipAccess(authenticator: StubAuthenticator(result: true), store: makeStore())
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        access.noteUnlocked(id, now: start)
        XCTAssertTrue(access.isUnlocked(id, now: start.addingTimeInterval(SensitiveClipAccess.graceInterval - 1)))
        XCTAssertFalse(access.isUnlocked(id, now: start.addingTimeInterval(SensitiveClipAccess.graceInterval + 1)))
    }

    func testRelockClosesTheWindowEarly() async {
        let store = makeStore()
        let entry = seeded(store)
        let auth = StubAuthenticator(result: true)
        let access = SensitiveClipAccess(authenticator: auth, store: store)

        _ = await access.plaintext(for: entry, reason: "reveal")
        access.relock(entry.id)
        _ = await access.plaintext(for: entry, reason: "copy")
        XCTAssertEqual(auth.callCount, 2, "hiding a revealed clip must re-arm the prompt")
    }

    func testRelockAllClosesEveryWindow() {
        let access = SensitiveClipAccess(authenticator: StubAuthenticator(result: true), store: makeStore())
        let a = UUID(), b = UUID()
        access.noteUnlocked(a)
        access.noteUnlocked(b)
        access.relockAll()
        XCTAssertFalse(access.isUnlocked(a))
        XCTAssertFalse(access.isUnlocked(b))
    }

    /// Even with the key store gone the gate must not hand back garbage.
    func testUndecryptableClipYieldsNothingAfterSuccessfulAuth() async {
        let store = ClipboardHistoryStore(
            fileURL: tempDir.appendingPathComponent("clipboard-history.json"),
            keyStore: UnavailableClipboardKeyStore(),
            limits: .init(maxEntries: 100, maxAgeDays: 7)
        )
        // Hand-build a sealed-looking entry (record() would have refused it).
        let entry = ClipboardEntry(
            kind: .text,
            isSensitive: true,
            sensitiveShape: CredentialShape.tokenPrefix.rawValue,
            sealed: Data([0x01, 0x02, 0x03]),
            fingerprint: "abc"
        )
        let access = SensitiveClipAccess(authenticator: StubAuthenticator(result: true), store: store)
        let plain = await access.plaintext(for: entry, reason: "test")
        XCTAssertNil(plain)
    }

    /// The guard that stops a suite raising a real Touch ID sheet.
    func testDeviceOwnerAuthenticatorRefusesUnderXCTest() async {
        let authed = await DeviceOwnerAuthenticator.shared.authenticate(reason: "test")
        XCTAssertFalse(authed)
    }
}

// MARK: - What the UI is allowed to show

@MainActor
final class SensitiveCardPresentationTests: XCTestCase {

    private func sealedCard(fingerprint: String? = nil) -> UnifiedCard {
        UnifiedCard(source: .transient(ClipboardEntry(
            kind: .text,
            isSensitive: true,
            sensitiveShape: CredentialShape.tokenPrefix.rawValue,
            sealed: Data([0xAA, 0xBB]),
            fingerprint: fingerprint
        )))
    }

    private func plainCard(_ text: String) -> UnifiedCard {
        UnifiedCard(source: .transient(ClipboardEntry(kind: .text, content: text)))
    }

    func testSealedCardExposesNoText() {
        let card = sealedCard()
        XCTAssertTrue(card.isSensitive)
        XCTAssertTrue(card.rawText.isEmpty, "rawText is what previews, tooltips and sends read")
        XCTAssertTrue(card.previewText.isEmpty)
        XCTAssertNil(card.sendPayload, "sends must go through the auth gate, not the card")
    }

    func testSealedCardCarriesItsShapeLabel() {
        XCTAssertEqual(sealedCard().sensitiveLabel, CredentialShape.tokenPrefix.label)
    }

    /// A sealed clip must not be sniffed for a colour/link shape — the card is
    /// always plain text, so no structure of the secret reaches the renderer.
    func testSealedCardIsAlwaysTextKind() {
        XCTAssertEqual(sealedCard().kind, .text)
    }

    func testSealedCardIsExcludedFromSearch() {
        let card = sealedCard()
        XCTAssertFalse(UnifiedShelfViewModel.matches(card, query: "a"))
        XCTAssertFalse(UnifiedShelfViewModel.matches(card, query: "token"))
        XCTAssertTrue(UnifiedShelfViewModel.matches(card, query: ""), "it still belongs in the unfiltered feed")
    }

    func testOrdinaryCardsStillMatchSearch() {
        XCTAssertTrue(UnifiedShelfViewModel.matches(plainCard("hello world"), query: "world"))
    }

    /// Two different secrets must not collide on an empty identity key, or the
    /// feed would dedupe them into one card. Same fingerprint = same secret, so
    /// those SHOULD collide.
    func testSealedIdentityKeysFollowTheFingerprint() {
        XCTAssertNotEqual(sealedCard().identityKey, sealedCard().identityKey)
        XCTAssertEqual(sealedCard(fingerprint: "f00d").identityKey, sealedCard(fingerprint: "f00d").identityKey)
        XCTAssertNotEqual(sealedCard(fingerprint: "f00d").identityKey, sealedCard(fingerprint: "beef").identityKey)
    }

    func testSealedIdentityKeyIsNamespacedAwayFromText() {
        XCTAssertTrue(sealedCard().identityKey.hasPrefix("sensitive://"))
        XCTAssertTrue(plainCard("").identityKey.hasPrefix("text://"))
    }
}
