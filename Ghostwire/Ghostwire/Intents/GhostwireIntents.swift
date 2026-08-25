//
//  GhostwireIntents.swift
//  Ghostwire
//
//  GW-452: expose Ghostwire as App Intents so Shortcuts and Siri can drive it
//  without us shipping a model.
//
//  Scope is deliberately narrow: only actions a global hotkey CANNOT do. The
//  open-on-tab and jump-to-pending intents were built and cut, because they
//  only duplicated the GW-286/GW-267 hotkeys — a keypress already does that
//  faster. What a keypress cannot do is carry an argument in or hand a value
//  back out, which is exactly what these two are for.
//
//  APPROVALS ARE DELIBERATELY ABSENT, and so is anything that widens security
//  posture (mcpServeEnabled, the gateway, granting a server access). GW-408/413
//  settled that only a person clicking at the notch may write a verdict; an
//  intent can be fired by an automation, so exposing one would let something
//  that isn't a deliberate human click resolve a gate. Consent decisions are
//  the same class of problem. Approvals are GW-282's territory, not this file's.
//

import AppIntents
import AppKit
import Foundation

/// Save a passed string to the Shelf. The argument is the whole point — the
/// Shelf hotkeys can only capture what's already on the clipboard.
///
/// Mirrors what the Shelf's own capture paths do (`ClipboardHistoryView`,
/// `VoiceCaptureViewModel`, `ShelfDropService`): a web URL becomes a `.link`
/// item so it renders and opens as a link, anything else becomes `.text`.
struct SaveToShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Shelf"
    static var description = IntentDescription(
        "Saves text or a link to Ghostwire's Shelf.",
        categoryName: "Shelf"
    )
    // Pure store write — no reason to pull the app forward.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to the Shelf")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GhostwireIntentError.emptyText
        }

        // ShelfDropService treats ANY non-file URL as a link, so restricting to
        // http/https here would downgrade deep links (slack://, linear://,
        // mailto:) to unopenable text. But that service is handed a URL the
        // drag payload already declared; we're handed free text and have to
        // guess, and URL(string:) is far looser than it looks — "TODO: fix this"
        // parses with scheme "TODO", "note:remember milk" with scheme "note".
        // Whitespace is what separates the two: a real URL has none, and every
        // false positive measured did. Verified against both sets.
        let item: ShelfItem
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let url = URL(string: trimmed),
           url.scheme != nil,
           !url.isFileURL {
            item = ShelfItem(kind: .link(url: url))
        } else {
            item = ShelfItem(kind: .text(string: trimmed))
        }

        ShelfStateViewModel.shared.add([item])
        return .result()
    }
}

/// Read the Shelf back out into a Shortcut. Returning a value is the point —
/// a hotkey can only cause a side effect, it can never hand data to the next
/// step of an automation.
///
/// UNGATED, decided 2026-08-25 after review. The risk considered and accepted:
/// an App Shortcut is NOT invocable from `shortcuts run` (measured — it answers
/// "Couldn't find shortcut"), but once a user SAVES a shortcut containing this
/// action, any local process can run it by name with no prompt and read Shelf
/// text back on stdout. That is user-initiated, and anyone who can run
/// `shortcuts` as this user can already read `ShelfPersistenceService.storeURL`
/// off disk — so a consent gate here would buy no real containment. Note this
/// is deliberately a WEAKER stance than the MCP serve path, which gates the
/// same data behind `Defaults[.mcpServeEnabled]`; that gate exists because MCP
/// serve exposes the Shelf to a remote agent, not to the user's own automations.
/// If Shelf items ever start holding credentials by design (GW-166's territory),
/// revisit this.
struct GetShelfItemsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Shelf Items"
    static var description = IntentDescription(
        "Returns what's held on Ghostwire's Shelf, newest first. Optionally filtered by a search term.",
        categoryName: "Shelf"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Search", description: "Only return items containing this text. Leave empty for everything.")
    var search: String?

    @Parameter(title: "Limit", description: "Maximum number of items to return.", default: 25)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get Shelf items matching \(\.$search)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        // displayName is what the Shelf itself renders, so a Shortcut sees the
        // same label the user sees in the notch. It is NOT cheap for a .file
        // item: it resolves a security-scoped bookmark and may read+decode a
        // JSON/plist sidecar. Mapping it eagerly across the whole Shelf would
        // put bulk synchronous disk I/O on the main actor and stall the notch
        // while a Shortcut runs — so walk lazily and stop at the limit rather
        // than computing every name and then throwing most of them away.
        // Empty or whitespace-only search means "everything", not "match the
        // empty string".
        let trimmedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let term: String? = trimmedSearch.isEmpty ? nil : trimmedSearch
        // A non-positive limit means "no limit" rather than "return nothing" —
        // an empty result would read as "the Shelf is empty", which is a lie.
        let cap = limit > 0 ? limit : Int.max

        var names: [String] = []
        for item in ShelfStateViewModel.shared.items {
            if names.count >= cap { break }
            let name = item.displayName
            if let term, !name.localizedCaseInsensitiveContains(term) { continue }
            names.append(name)
        }

        return .result(value: names)
    }
}

enum GhostwireIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText: return "There was nothing to save."
        }
    }
}

/// Registers the intents with Shortcuts + Siri. Phrases must contain
/// `\(.applicationName)` or the provider is rejected at build time.
struct GhostwireAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveToShelfIntent(),
            phrases: [
                "Save this to \(.applicationName)",
                "Add to the \(.applicationName) Shelf",
            ],
            shortTitle: "Save to Shelf",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: GetShelfItemsIntent(),
            phrases: [
                "What's on my \(.applicationName) Shelf",
                "Get \(.applicationName) Shelf items",
            ],
            shortTitle: "Get Shelf Items",
            systemImageName: "tray.full"
        )
    }
}
