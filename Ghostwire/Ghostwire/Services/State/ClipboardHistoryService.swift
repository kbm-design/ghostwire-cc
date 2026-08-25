//
//  ClipboardHistoryService.swift
//  Ghostwire
//
//  GW-210: clipboard capture. Polls NSPasteboard.general's `changeCount` on a
//  ~0.5s timer (the standard macOS pattern — there is no pasteboard-changed
//  notification). The timer only runs while the app runs; no background daemon
//  semantics. v1 captures plain text (`.string`) and file URLs (`.fileURL`,
//  recorded as paths).
//
//  PRIVACY (GW-210 hard requirements):
//   • Skip when the pasteboard declares `org.nspasteboard.ConcealedType` or
//     `org.nspasteboard.TransientType` — password managers mark copies this
//     way (the de-facto NSPasteboard privacy convention).
//   • Skip our own writes: re-copy stamps a private marker type
//     (`ghostwireMarkerType`) so the next poll ignores the change we caused.
//   • Cap captured text length (`maxTextBytes`, default 100 KB) and flag the
//     entry as truncated.
//  Nothing leaves the machine (local-first) — capture → local store only.
//
//  The privacy + extraction logic lives in `ClipboardSnapshot` /
//  `entry(from:)` as a pure seam over a value type, so it's unit-testable
//  without a live pasteboard (ClipboardHistoryServiceTests).
//
//  GW-166 adds one more rule to that same seam: credential-SHAPED text (a token
//  prefix, a JWT, a PEM block, a high-entropy blob) is flagged `isSensitive` so
//  the store seals it. That's the gap the concealed/transient convention leaves
//  open — it only covers apps that opt in, and a token copied out of a terminal
//  or a web dashboard carries no marker at all. Detection is flagging only; the
//  concealed/transient skip above is untouched, and a marked copy is still never
//  captured in the first place.
//

import AppKit
import Combine
import Defaults
import Foundation

/// A pure value-type snapshot of the pasteboard state we care about, so the
/// privacy + extraction rules can be exercised in tests without AppKit.
struct ClipboardSnapshot: Equatable {
    /// Raw type identifiers present on the pasteboard (`type.rawValue`).
    var types: [String]
    /// `.string` plain-text payload, if any.
    var string: String?
    /// `.fileURL` path payload, if any.
    var filePath: String?
    /// Bundle id of the frontmost app at capture (best-effort).
    var sourceBundleId: String?

    // The two NSPasteboard privacy markers (the community convention password
    // managers honor). String literals so we don't need the constants linked.
    static let concealedType = "org.nspasteboard.ConcealedType"
    static let transientType = "org.nspasteboard.TransientType"
    /// Our own marker — set on re-copy so the next poll ignores it.
    static let ghostwireMarkerType = "com.ghostwire.clipboard.own-write"

    var isConcealedOrTransient: Bool {
        types.contains(Self.concealedType) || types.contains(Self.transientType)
    }

    var isOwnWrite: Bool {
        types.contains(Self.ghostwireMarkerType)
    }
}

enum ClipboardCapture {
    /// Pure: derive the entry to record from a snapshot, applying every privacy
    /// rule and the text-length cap. Returns nil when nothing should be
    /// recorded (concealed/transient, our own write, or no usable payload).
    ///
    /// `protectCredentials` (GW-166, `Defaults[.clipboardCredentialProtection]`,
    /// passed in rather than read here so this stays pure and the tests never
    /// touch the live defaults domain) runs the shape heuristics over the text
    /// and flags a match. Flagging only — the store does the sealing.
    static func entry(
        from snapshot: ClipboardSnapshot,
        maxTextBytes: Int,
        protectCredentials: Bool
    ) -> ClipboardEntry? {
        // Privacy gates first — never inspect payloads of a protected copy.
        guard !snapshot.isConcealedOrTransient, !snapshot.isOwnWrite else { return nil }

        // Prefer file URLs (they're the higher-signal capture); fall back to
        // plain text. Empty/whitespace-only text is ignored.
        if let path = snapshot.filePath, !path.isEmpty {
            return ClipboardEntry(
                kind: .file,
                path: path,
                sourceBundleId: snapshot.sourceBundleId
            )
        }

        if let raw = snapshot.string {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Detect on the RAW text, before the byte cap — a long PEM block
            // truncated mid-key is still a private key.
            let shape = protectCredentials ? CredentialShapeDetector.shape(of: raw) : nil
            let (capped, truncated) = cap(raw, maxBytes: maxTextBytes)
            return ClipboardEntry(
                kind: .text,
                content: capped,
                sourceBundleId: snapshot.sourceBundleId,
                truncated: truncated,
                isSensitive: shape != nil,
                sensitiveShape: shape?.rawValue
            )
        }

        return nil
    }

    /// Cap `text` to `maxBytes` UTF-8 bytes, never splitting a character.
    /// Returns the (possibly truncated) string and whether truncation happened.
    static func cap(_ text: String, maxBytes: Int) -> (String, Bool) {
        guard maxBytes > 0 else { return ("", !text.isEmpty) }
        if text.utf8.count <= maxBytes { return (text, false) }
        var result = ""
        var byteCount = 0
        for ch in text {
            let chBytes = String(ch).utf8.count
            if byteCount + chBytes > maxBytes { break }
            result.append(ch)
            byteCount += chBytes
        }
        return (result, true)
    }
}

@MainActor
final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService()

    /// Default cap on captured text payloads (100 KB), per the GW-210 spec.
    static let maxTextBytes = 100 * 1024

    private let pasteboard: NSPasteboard
    private let store: ClipboardHistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var enabledCancellable: AnyCancellable?

    init(
        pasteboard: NSPasteboard = .general,
        store: ClipboardHistoryStore = .shared
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Start/stop polling to follow the master toggle. Safe to call at launch.
    func start() {
        store.warm()
        enabledCancellable = Defaults.publisher(.clipboardHistoryEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    if change.newValue { self?.startPolling() } else { self?.stopPolling() }
                }
            }
        if Defaults[.clipboardHistoryEnabled] { startPolling() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        // Don't capture whatever was already on the pasteboard at start.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let snap = snapshot(of: pasteboard)
        // Mirrors ShelfDropService.processProvider's capture priority for COPY:
        //   1) file-url  -> record the path (sends as @path)
        //   2) image/data bytes, no file -> spill to a temp file (isTemporary)
        //   3) text      -> inline
        let entry = ClipboardCapture.entry(
            from: snap,
            maxTextBytes: Self.maxTextBytes,
            protectCredentials: Defaults[.clipboardCredentialProtection]
        )

        // Tier 1: a file URL wins outright.
        if let entry, entry.resolvedKind == .file {
            store.record(entry)
            return
        }
        // Tier 2: raw image bytes (e.g. "Copy Image") beat plain text.
        if !snap.isConcealedOrTransient, !snap.isOwnWrite,
           let (data, ext) = imageData(from: pasteboard) {
            spillImageAndRecord(data: data, ext: ext, sourceBundleId: snap.sourceBundleId)
            return
        }
        // Tier 3: text.
        if let entry {
            store.record(entry)
        }
    }

    /// Raw image bytes on the pasteboard (PNG preferred, then TIFF), with the
    /// file extension to use for the spilled temp file. Nil when no image.
    private func imageData(from pb: NSPasteboard) -> (Data, String)? {
        if let d = pb.data(forType: .png) { return (d, "png") }
        if let d = pb.data(forType: .tiff) { return (d, "tiff") }
        return nil
    }

    /// Spill copied image bytes to a temp file and record a `.file` entry flagged
    /// `isTemporary` so it's reaped when it leaves history.
    private func spillImageAndRecord(data: Data, ext: String, sourceBundleId: String?) {
        Task { @MainActor in
            let name = "clipboard-image.\(ext)"
            guard let url = await TemporaryFileStorageService.shared.createTempFile(
                for: .data(data, suggestedName: name)
            ) else { return }
            store.record(ClipboardEntry(
                kind: .file,
                path: url.path,
                sourceBundleId: sourceBundleId,
                isTemporary: true
            ))
        }
    }

    /// Read the bits of the live pasteboard we care about into a value type.
    /// Codex review P2: check the declared types BEFORE touching any payload -
    /// concealed/transient (password managers) and our own writes must never
    /// be read into this process at all, not just rejected after the fact.
    private func snapshot(of pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let gate = ClipboardSnapshot(types: types, string: nil, filePath: nil, sourceBundleId: nil)
        guard !gate.isConcealedOrTransient, !gate.isOwnWrite else { return gate }

        // Read a file URL first (Finder copies set both .fileURL and .string).
        var filePath: String?
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = url.first, first.isFileURL {
            filePath = first.path
        }
        return ClipboardSnapshot(
            types: types,
            string: pasteboard.string(forType: .string),
            filePath: filePath,
            sourceBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    /// Re-copy an entry back to the pasteboard, stamping our marker type so the
    /// next poll ignores the change we just caused (GW-210 own-write skip).
    /// Declares all types up front (declareTypes) so the marker and the payload
    /// coexist — setString after writeObjects on an undeclared type is a no-op.
    /// GW-166: a sealed entry has no plaintext to hand out here. Callers must go
    /// through `SensitiveClipAccess` and then `stagePlainTextForPaste(_:)` — this
    /// refuses rather than silently copying an empty pasteboard.
    func recopy(_ entry: ClipboardEntry) {
        guard !entry.isSensitive else { return }
        let markerType = NSPasteboard.PasteboardType(ClipboardSnapshot.ghostwireMarkerType)
        switch entry.resolvedKind {
        case .text:
            guard let content = entry.content else { return }
            pasteboard.declareTypes([.string, markerType], owner: nil)
            pasteboard.setString(content, forType: .string)
            pasteboard.setString("1", forType: markerType)
        case .file:
            guard let path = entry.path else { return }
            let url = URL(fileURLWithPath: path)
            pasteboard.declareTypes([.fileURL, .string, markerType], owner: nil)
            pasteboard.setString(url.absoluteString, forType: .fileURL)
            pasteboard.setString(url.path, forType: .string)
            pasteboard.setString("1", forType: markerType)
        }
        // Keep changeCount in sync so poll() treats this as our write even if
        // the timer fires before the marker is observed.
        lastChangeCount = pasteboard.changeCount
    }

    // MARK: - GW-218 unified-card pasteboard actions

    /// "Copy" a card back to the live clipboard (marker-stamped so auto-capture
    /// ignores our own write). Files re-copy as real file URLs so they paste into
    /// Finder; everything else copies as a plain string.
    func copyCardToPasteboard(_ card: UnifiedCard) {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshot.ghostwireMarkerType)
        switch card.kind {
        case .image, .file:
            if let url = card.fileURL {
                pasteboard.declareTypes([.fileURL, .string, marker], owner: nil)
                pasteboard.setString(url.absoluteString, forType: .fileURL)
                pasteboard.setString(url.path, forType: .string)
                pasteboard.setString("1", forType: marker)
            } else {
                stageString(plainText(for: card), marker: marker)
            }
        default:
            stageString(plainText(for: card), marker: marker)
        }
        lastChangeCount = pasteboard.changeCount
    }

    /// Stage a card's plain-text on the pasteboard ahead of a synthesized ⌘V
    /// (the "Paste into current field" action). Always a string — a file pastes
    /// its `@path`-friendly path, not a file ref.
    func stagePlainTextForPaste(_ card: UnifiedCard) {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshot.ghostwireMarkerType)
        stageString(plainText(for: card), marker: marker)
        lastChangeCount = pasteboard.changeCount
    }

    /// Put plain text on the pasteboard as our own write (GW-229 voice
    /// transcript) so it's the live clipboard / pasteable, WITHOUT the poller
    /// re-capturing it into clipboard history — the Shelf is the durable record.
    func stagePlainTextForPaste(_ string: String) {
        let marker = NSPasteboard.PasteboardType(ClipboardSnapshot.ghostwireMarkerType)
        stageString(string, marker: marker)
        lastChangeCount = pasteboard.changeCount
    }

    private func stageString(_ string: String, marker: NSPasteboard.PasteboardType) {
        pasteboard.declareTypes([.string, marker], owner: nil)
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("1", forType: marker)
    }

    private func plainText(for card: UnifiedCard) -> String {
        switch card.kind {
        case .image, .file: return card.fileURL?.path ?? card.previewText
        case .link: return card.linkURL?.absoluteString ?? card.rawText
        default: return card.rawText
        }
    }
}
