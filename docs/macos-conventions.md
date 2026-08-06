# Ghostwire — macOS / AppKit conventions

Platform constraints and native patterns that shape **how** we design and build
Ghostwire on macOS. Pairs with [`design-system.md`](./design-system.md) (the
visual + motion language). For build/release trip-wires see the
`ghostwire-codebase` skill; for deeper API guidance see the `macos-development`,
`macos-design-guidelines`, and `swiftui-expert` skills.

---

## 1. App shape — `LSUIElement` (menu-bar / notch only)

Ghostwire runs as an agent app: **no Dock icon, no standard menu bar, no
scriptable/AX windows, no URL scheme.** Design consequences:
- You **cannot script-drive the UI** — specific states (approval pending,
  populated shelf, glow, recording) need a **live session / manual capture**.
  Don't design flows that assume automated screenshotting.
- Entry points are the **notch**, the **menu-bar item**, and global hotkeys —
  there's no app menu to hang commands off. Put controls in the notch header,
  Settings, or shortcuts.

## 2. Not sandboxed → not Mac App Store

Needs a Unix socket (`/tmp/com.ghostwire.notch.sock`) + broad file access, so
it's **non-sandboxed** and distributed by **direct download / Homebrew** (not
MAS). No sandbox/entitlement gymnastics to design around — but we self-impose
**local-first / privacy** (observation, Shelf store, MCP transport stay local).

## 3. The notch is a borderless `NSPanel` in a `CGSSpace` at a very high window level

It **outranks every system panel.** This is the single biggest interaction
constraint:
- **NEVER present an `NSOpenPanel` / `NSAlert` / sheet / dialog while the notch is
  open** — it renders *behind* the notch and deadlocks. Hold the notch open
  across the interaction with `SharingStateManager.shared.beginInteraction()` /
  `endInteraction()`.
- **Focus:** `canBecomeKey` is gated so **passive reveals never steal focus** —
  an ambient surface appearing must not pull the user out of their terminal.
  Only an explicit user action (open, authorize) may take key.
- **The notch is a drawn shape** (`NotchShape`, topRadius 6 / bottomRadius 14) on
  pure black — not a window with a background. Don't approximate it with a plain
  rounded rectangle.
- **Multi-display:** respect `showOnAllDisplays` / `automaticallySwitchDisplay`;
  the notch binds to the physical notch width on the active display.

## 4. SwiftUI + AppKit bridging

- SwiftUI content is hosted in AppKit windows via `NSHostingView`; low-level bits
  use `NSViewRepresentable`. State is `@Observable` (Swift 6.2 approachable
  concurrency — see the `swift-concurrency-6-2` skill).
- The **detached window** (GW-223) is a real resizable `NSWindow` hosting the full
  app; a `GhostwireSurface` `.notch` / `.window` environment flag lets the same
  SwiftUI views render in both. Design surfaces to work at both notch size and
  window size.
- New Swift files must live under the nested synced group `Ghostwire/Ghostwire/…`
  (files under `components/` / `models/` are explicit pbxproj refs and silently
  won't compile) — see `ghostwire-codebase`.

## 5. Native controls & HIG alignment

- **Settings** is the one surface that **follows system light/dark** — build both.
  Use native SwiftUI **`Form`** with **`Toggle` / `Picker` / `Slider`**; don't
  hand-roll controls there. `NavigationSplitView` with a searchable sidebar.
  That covers *which control*. For everything in Settings that isn't a `Form`
  row — sheet widths, list-row anatomy, empty/loading/error states, status
  vocabulary, inline security copy, and the light-mode `state/` tokens — see
  [`design-system.md`](./design-system.md) **§8**.
- Use **SF Symbols** for iconography (weight `.medium`); use `.rounded` numerals
  for HUD/usage.
- **Keyboard:** global hotkeys open/jump the notch; approval Approve/Deny/Open-
  Terminal are keyboard-reachable and gated to the focused chat. Provide
  shortcuts for primary actions; show them in the UI.
- **Menu-bar etiquette:** the menu-bar item is a status affordance, not a command
  dumping ground.

## 6. Accessibility (the ability spectrum)

- **VoiceOver:** label status dots, meters, and icon-only buttons (their meaning
  is otherwise color/position-only).
- **Reduce Motion:** honor it — dwell auto-dismiss recedes to a glow and
  **pauses on hover**; never signal by motion alone.
- **Contrast / low vision:** the UI leans on a white-opacity ladder on black —
  keep primary text ≥ `text/primary` (white 90%); don't drop meaningful text
  below `text/secondary`. Pair color state (read-only/destructive) with text.
- **Sunlight / colorblind:** don't rely on the terminal palette alone to convey
  state.

## 7. Targets & versions

- Deployment target **macOS 14.0**; build with **`-scheme Ghostwire`** (a bare
  `-target` fails — SPM products link via the scheme).
- macOS 26 `SpeechAnalyzer` is a **dormant `#if compiler(>=6.2)` seam** (current
  Xcode can't compile it); `SFSpeechRecognizer` on-device is what ships today.
- Signing / notarization / Sparkle release flow: see `ghostwire-codebase` and
  `release.sh`. **Never** regenerate the Sparkle EdDSA key.

---

See also: [`design-system.md`](./design-system.md), the `ghostwire-codebase`
skill (build/release/gotchas), and Apple's Human Interface Guidelines for
menu-bar apps, windows, and accessibility.
