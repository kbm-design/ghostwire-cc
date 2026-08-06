# Dashboard feed curation — design

Date: 2026-06-19 · Project: Ghostwire (Notch Command Center) · Linear: GW-259 / GW-273
Builds on: the GW-259 card-rendering layer (`FeedCard` + `FeedCardView`, already built on branch `keelanmiskell/gw-259-…`).

## Context

The GW-259 rendering layer can draw a `FeedCard`, but cards are hardcoded sample data with no ordering or curation. Keelan wants the Dashboard to become a **manageable feed**: the notch shows a curated top-N row, the detachable window shows the full reorderable list, and **reordering in the window flows back to what the notch shows**. This is the manual-ordering "v1" the GW-259 ticket always intended ("keep FeedCard ranking-agnostic — v1 is manual/source-order; GW-182 context ranking sorts it later with no model change").

Cards stay sample data for now (real `Source`s land later); the curation UX is built against a shared sample store and swaps to real Sources with **zero UX change**.

## Goal

One shared, persisted, ordered card store read by two surfaces:
- **Notch Dashboard** — top-N cards in a horizontal row, alongside the existing media controls (coexist).
- **Detachable window Dashboard** — the full vertical list, drag-reorderable, with a divider marking the notch-visible cutoff.

Reorder in the window → store → notch row + window list both update reactively.

## Scope

**In:** `FeedCardStore` (shared, observable, persisted order); the notch top-N row; the detachable-window `.dashboard` tab + full reorderable list; reshuffle motion; tests.

**Out (flag if pulled in):** real `Source` protocol / backends (app/mcp/api), GW-182 automatic ranking, the cards-replace-controls IA decision (**GW-288**), any notch-height/sizing changes beyond fit-or-scroll.

## Architecture

### `FeedCardStore` — single source of truth
New file `Ghostwire/Ghostwire/Services/Feed/FeedCardStore.swift` (synced root → auto-compiles).

```swift
@Observable
@MainActor
final class FeedCardStore {
    static let shared = FeedCardStore()

    /// All cards in user order (the persisted order applied to live cards).
    private(set) var orderedCards: [FeedCard] = []

    /// The first N of orderedCards are mirrored into the notch.
    var notchVisibleCount: Int { Defaults[.feedNotchVisibleCount] }   // default 8

    var notchCards: [FeedCard] { Array(orderedCards.prefix(notchVisibleCount)) }

    /// Replace the live card set (later: called by Sources; now: seeded with samples).
    func setCards(_ cards: [FeedCard]) { … reconcile against persisted order … }

    /// Drag-reorder from the window list. Writes the new id order to Defaults.
    func move(fromOffsets: IndexSet, toOffset: Int) { … withAnimation, persist … }
}
```

### Ordering model
- Order persists as **`Defaults[.feedCardOrder]: [String]`** — an array of stable `FeedCard.id`s (same idiom as `notchTabOrder`/`NotchTab.sanitizedOrder`).
- **Reconciliation** when the live card set changes (`setCards`): keep known ids in their saved position; **new ids append at the bottom** (source order); **vanished ids drop out** of both the order array and the list. This is why ids must be stable across refreshes (the rendering-layer `FeedCard.id` already is).
- `notchVisibleCount` is a `Defaults` key (default 8), so "5–10 in the notch" is tunable without code change.

### Surfaces

**Notch Dashboard** (`components/Notch/NotchHomeView.swift`): restore `mainContent` (music/calendar/camera) and add the feed row beneath it in a `VStack`:
```
VStack { mainContent ; FeedCardRow(cards: store.notchCards) }
```
`FeedCardRow` = horizontal `ScrollView`/`LazyHStack` of `FeedCardView` over `store.notchCards`. *Constraint:* the open notch is fixed 190pt and `mainContent` is tall — the feed row must be compact and the Dashboard content vertically scrollable within that height; **do not grow the notch**. Confirm fit live.

**Detachable window Dashboard** (`UI/ShelfWindow/GhostwireWindowView.swift`): add `.dashboard` to `GhostwireWindowTab` (label "Dashboard", icon `square.grid.2x2`), rendered as:
- the same coexist layout (media controls on top — pass a local `@Namespace` for `NotchHomeView`'s `albumArtNamespace`), then
- a `List { ForEach(store.orderedCards) { FeedCardRowItem } .onMove(perform: store.move) }` — native macOS drag-to-reorder. A non-row divider/label after index `notchVisibleCount` reads "↑ shown in the notch". Promote a card into the notch = drag it above the divider.

### Data flow
`window .onMove` → `store.move` (mutates `orderedCards`, writes `Defaults[.feedCardOrder]`) → store is `@Observable` + `shared` → notch `FeedCardRow` and window `List` both re-read `orderedCards`/`notchCards` and update. One writer (the window list), two readers.

## Reshuffle motion
- **Window list:** `List` + `.onMove` provides the native reorder animation; no custom gesture/`matchedGeometryEffect` needed.
- **Notch row:** `ForEach(store.notchCards)` keyed by `FeedCard.id` (stable). Wrap the `store.move` mutation in `withAnimation(.spring(response: 0.35, dampingFraction: 0.8))` so cards entering/leaving the top-N and shifting position animate (SwiftUI animates moves of stably-identified views in an animation context).
- **Accessibility:** read `@Environment(\.accessibilityReduceMotion)`; when true, drop the spring (instant reorder) — `.animation(reduceMotion ? nil : .spring, value: store.orderedCards.map(\.id))`.
- Identity rules (per swiftui list-patterns): stable `id`, never `.indices`/`\.offset`, unary rows, no inline filtering (slice via `notchCards`, don't filter in the `ForEach`).

## Persistence
- `Defaults[.feedCardOrder]: [String]` (ordered ids), `Defaults[.feedNotchVisibleCount]: Int = 8`.
- Seed: on first run / for now, `FeedCardStore` seeds the sample cards (the gallery's data moves into the store; `FeedCardGalleryView` becomes a thin reader of `store` or is retired in favor of the real notch row).

## Testing
Pure store logic, mirroring `NotchTabTests` style (`@testable import Ghostwire`):
- `setCards` reconciliation: known ids hold position; new ids append; removed ids drop from order + list.
- `move` produces the expected order and persists the id array.
- `notchCards` returns exactly the first `notchVisibleCount`.
- Order round-trips through `Defaults` (save → reload → same order).
- Empty / fewer-than-N card sets behave (no out-of-range).

UI (drag, animation) verified live, not unit-tested.

## Workflow
Build (`xcodebuild -scheme Ghostwire build`) + tests → **Codex review before any commit** (findings surfaced to Keelan) → live smoke-test in the notch + detachable window → no commit/push/merge until Keelan approves (no-auto-merge). Branch: continues on the `gw-259` worktree (unmerged WIP); decide at plan time whether this extends GW-259 or becomes its own sub-ticket under GW-273.

## Revision — 2026-06-19 (post first smoke-test)

Live review showed the coexist layout was awkward on both surfaces. Revised per Keelan:
- **Notch:** the feed gets its **own notch tab** (`NotchTab.feed`, git-branch icon `arrow.triangle.branch`, `NotchViews.feed` → `FeedSurfaceView`) instead of sharing the Dashboard with the media controls. The Dashboard tab reverts to media-only (no vertical scroll-shrink). Notch feed tab = the horizontal top-N row.
- **Window:** drop the media controls; the `.feed` window tab (renamed from `.dashboard`) renders a **3–4-across `LazyVGrid`** of cards (`FeedGridView`), not the controls+list layout.
- **Parked:** because the window is now a grid (not a `List`), native drag-reorder + the top-N divider don't apply. Order comes from the store as-is; the notch shows the top-N. **Curation/reorder is deferred to the feed redesign** — `FeedCardStore`'s order model + `move` are kept in place for when it returns.

## Open follow-ups
- **GW-288** — evaluate feed cards replacing the media controls (filed).
- Agent-completion notch reveal (sound-but-no-reveal) — captured in the reveal-focus notes; not yet ticketed.
