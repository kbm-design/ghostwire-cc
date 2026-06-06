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
    static func entry(from snapshot: ClipboardSnapshot, maxTextBytes: Int) -> ClipboardEntry? {
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
            let (capped, truncated) = cap(raw, maxBytes: maxTextBytes)
            return ClipboardEntry(
                kind: .text,
                content: capped,
                sourceBundleId: snapshot.sourceBundleId,
                truncated: truncated
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

        guard let entry = ClipboardCapture.entry(
            from: snapshot(of: pasteboard),
            maxTextBytes: Self.maxTextBytes
        ) else { return }
        store.record(entry)
    }

    /// Read the bits of the live pasteboard we care about into a value type.
    private func snapshot(of pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let types = pasteboard.types?.map(\.rawValue) ?? []
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
    func recopy(_ entry: ClipboardEntry) {
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
}
