# Ghostwire — Design System

The single source of truth for building Ghostwire's UI consistently. Mirrors the
Figma **Foundations** page (fileKey `tgXXJAGWxqrojUNY7Hvroh`, "Ghostwire (dark)"
token collection) and adds the **motion** language, which lives only in code.

**Dark-only.** The notch is a *drawn shape on pure black* and has no light
variant. The **Settings window is the one surface that follows system
light/dark** — design both there, dark everywhere else. §1–§6 describe the
notch; **§8 describes Settings**, which composes differently and needs its own
color axis (§2 `state/`) because the notch's white-opacity ladder has no light
arm.

**Fonts.** `SF Pro` (system) for UI, `SF Mono` for code/commands, `.rounded`
for HUD/usage numerals. Figma uses **Inter** as a stand-in and **JetBrains
Mono** for mono (SF Mono isn't available in Figma) — rebind to SF Pro when
refining real assets.

---

## 1. Typography roles

Roles, not sizes — pick by what the text *is*. (`SF` = SF Pro unless noted.)

| Role | Spec | Use |
|---|---|---|
| Title | 28 · Semibold | window/page titles |
| Section | 18 · Semibold | section headers |
| Header / chat header | 14 · Semibold | pane + chat headers |
| Row title / emphasis | 13 · Medium (`.subheadline` ~13.5) | list row titles |
| Body / chat body | 13 · Regular (markdown) | assistant body, prose |
| Label · tool · tab | 12 · Medium | tab labels, tool names, controls |
| Caption / meter label | 11 · Regular (`.caption`) | meta, meter labels |
| Caption2 / timestamps | 11 (`.caption2`) + `monospacedDigit` | times, counts |
| Code / mono command | **SF Mono** 11–11.5 · Medium | commands, approvals, alert rows |
| Full-raw chat body | **mono** 12 | verbatim (`.fullRaw`) transcript |
| Thinking | 11 · Italic · gray | agent thinking |
| Subagent rows | 10 · Medium | nested subagent lines |
| Footer | 10 · Regular · `text/tertiary` | timestamps, sizes |
| Badge | 9 · Semibold · **CAPS** | capsule labels (CLAUDE, read-only) |

---

## 2. Color tokens ("Ghostwire (dark)")

Two axes: **`agent/`** encodes *which* agent (identity); **`terminal/`** encodes
*state*. Never mix them — a green dot means "state: ready", not "agent".

### agent/ — identity
| Token | Value | Meaning |
|---|---|---|
| `agent/claude` | `#DA7756` | canonical Claude peach (`AgentIdentity.swift:13`) |
| `agent/codex` | `rgb(0.04,0.64,0.50)` `#0AA380` | Codex teal |
| `agent/neutral` | white @ 62% | unknown agent / presence mark |
| `agent/claude-ALT` | `#D97857` | 2nd orange — Terminal prompt, Processing/NewMessages indicators |

Planned agents (identity palette): claude `#DA7756` · codex `#0AA380` · gemini
`#4F8DF6` · pi `#B47CFF` · cline `#E8833A` · kilo `#3FD17A` · neutral white 62%.
Unassigned agents auto-cycle a **stock pool**: `#E5594E` · `#F2853C` · `#2BC4FD`
· `#E368C6`.

### terminal/ — state
| Token | Value | Meaning |
|---|---|---|
| `terminal/green` | `rgb(0.4,0.75,0.45)` | ready / success / trusted |
| `terminal/amber` | `rgb(1,0.7,0)` | permission pending / needs action |
| `terminal/red` | `rgb(1,0.3,0.3)` | error / denied |
| `terminal/cyan` | `rgb(0,0.8,0.8)` | diff hunk headers |
| `terminal/blue` | `rgb(0.4,0.6,1)` | update states |
| `terminal/magenta` | `rgb(0.8,0.4,0.8)` | — |
| `terminal/dim` | white @ 40% | de-emphasized |
| `terminal/dimmer` | white @ 20% | hairlines, faint strokes |

### surface/ — fills (all white-on-black opacities unless noted)
`notch-bg` #000 (pure black — the notch is drawn on black) · `hover-row`
white 8% · `hover-icon` white 10% · `hover-subtle` white 5% (tool-call / code
hover) · `bar-track` white 8% (token mode: tint 18%) · `scrim-bar` black 20%
(header / input / approval-bar bg) · `badge-fill-claude` claude @ 18% ·
`badge-fill-codex` codex @ 18%.

### button/ + text/
`button/allow-fill` white 95% + **black** text (Allow / primary) ·
`button/deny-fill` white 10% + white text (Deny / secondary).
`text/primary` white 90% · `text/secondary` white 60% · `text/tertiary`
white 40% · `text/disabled` white 30%.

### state/ — Settings state (resolves per appearance)

`terminal/` is dark-only: every value above is a fixed sRGB constant chosen
against `#000`, and `dim`/`dimmer`/`surface/*`/`button/*` are white-opacity, so
on a light window background they composite to **1.00:1 — invisible**. Settings
therefore gets its own axis. Same *meanings*, one token each, resolved by
appearance — **not a parallel light table**.

Implement each as a single dynamic color (`NSColor(name:) { $0.bestMatch(...) }`
→ `Color(nsColor:)`), never as two tokens the call site picks between.

| Token | Meaning | Dark arm | Light arm | Contrast (dark / light) |
|---|---|---|---|---|
| `state/ok` | trusted · connected · installed · already set up | `#66BF73` (= `terminal/green`) | `#43844D` | 7.37 / 4.51 |
| `state/attention` | needs the user to act — not trusted, needs auth, re-trust, will be stored in plain text | `#FFB300` (= `terminal/amber`) | `#9D6E00` | 9.26 / 4.50 |
| `state/error` | failed — the thing did not work | `#FF4D4D` (= `terminal/red`) | `#DA3A3A` | 5.08 / 4.51 |
| `state/info` | neutral emphasis — schema, capability, link | `#6699FF` (= `terminal/blue`) | `#4A75C9` | 6.01 / 4.51 |
| `state/pending` | connecting · importing · probing | system `.secondary` + motion (`ProgressView`) | same | — |
| `state/inert` | disconnected · not detected · nothing configured yet | system `.secondary` | same | — |

Ratios measured against `NSColor.windowBackgroundColor` (`#1E1E1E` dark,
`#FFFFFF` light), sRGB, WCAG 2.x. **Dark arms are the existing `terminal/`
values verbatim** so a state means the same color in both halves of the app.

**Non-text rung.** Dots, hairlines and badge strokes need 3:1, not 4.5:1. Where
a 4.5:1 arm reads muddy as a 6–8px dot, the light arm may relax to:
`ok #55A660` · `attention #C58A00` · `error #FF4444` · `info #5D92FC`
(3.00–3.41:1). **Text always takes the 4.5:1 arm.**

**Do not** use bare SwiftUI `.red` / `.orange` / `.green` / `.yellow` for state.
They resolve to `#34C759` / `#FF8D28` / `#FFCC00` on a light window background —
**2.22 / 2.31 / 1.51:1**, well under the 3:1 floor even for a dot. (Every
Settings pane does this today; see §8.4.)

**System label colors stay system.** `state/` replaces `terminal/` only for
*state*. Text rank in Settings uses `.primary` / `.secondary` / `.tertiary`,
which resolve correctly per appearance — `text/primary…disabled` are notch-only.
Note `.secondary` composites to **3.95:1 in light** (5.89:1 in dark): fine for
supporting meta, **not** for a line the user must read to make a safe choice
(§8.5).

**`agent/` identity stretches; text is the exception.** `agent/claude #DA7756`
is 3.11:1 on white and `agent/codex #0AA380` is 3.19:1 — enough for a dot or a
badge fill, not for text. In Settings, agent identity is a **fill or a dot,
never a text color**. If an agent tint must carry text in light mode, use the
4.5:1 arms `claude #B45E42` / `codex #028768`.

**Accessibility:** never encode meaning by color alone — read-only / destructive
badges pair the color with a text label. Honor the ability spectrum (screen
reader labels on dots/meters; contrast on the white-opacity ladder).

---

## 3. Spacing & shape

**Spacing scale (itemSpacing / padding, px):** `2 · 4 · 6 · 8 · 10 · 12 · 14 · 16`
— plus `20 · 24` **in Settings only**, for sheet insets and window-scale gutters.
The notch tops out at 16 because it is 640 wide; a 520-wide sheet inside a 700
window does not, and all three MCP sheets already inset at 20. Don't bring 20/24
back into the notch.

**Corner radii:** `6` icon-btn / code · `8` rows · `10` · `12` card / instance-row
hover / Shelf card · `13` · `18` user bubble · `20` input · `2` bar fill ·
capsule for pills. **NotchShape:** topCornerRadius `6`, bottomCornerRadius `14`
(drawn path — don't approximate with a plain rounded rect).

**Row padding:** instance `8/14` h, `10` v · bars `16` h, `12` v · minHeight `44`
· alert rows `8` h, `7` v.
**Stacks:** instance `HStack 10` · messages `LazyVStack 16` · meters `HStack 12`
· list `LazyVStack 2`.
**Dots / sizes:** state dot `6×6` · subagent `4×4` · alert disc `22×22` · usage
bar height `4` (radius 2) · icon buttons `24×24`.

**Key dimensions:** open notch `640×190` (grows taller for chat) · closed notch
`~185×~32` (width = physical notch) · detached window `920×640` default,
resizable (min `640×420`) · Shelf card `176×110` r12 · notch corner insets
opened `19/24` · closed `6/14`.

---

## 4. Motion & timing

The app's motion language — snappy, minimal overshoot, short. Extracted from the
SwiftUI source; **this is the part the Figma foundations don't cover.**

**Springs** (`.spring(response:dampingFraction:)`):
| Response / Damping | Use |
|---|---|
| `0.3 / 0.7` | **default** — most transitions |
| `0.25 / 0.8` | snappier, small elements |
| `0.35 / 0.7–0.85` | larger reveals (approval entrance, notch open) |
| `0.2 / 0.7` | tiny / micro |

**Durations & easing:** `0.15s` micro · `0.2s` **default** · `0.3s` larger.
`easeOut` for enter/appear, `easeInOut` for state changes.

**Named motions:**
- **Glow (GW-138)** — passive alert. 2 shadows, tinted to the active `agent/`
  color, `r14 + r24 @ 0.6`; pulse **`0.25s in / 400ms hold / 1.0s out`**.
- **Approval entrance** — staggered spring reveal of chat / Deny / Allow.
- **Notch open** — closed → open expand (spring `0.35 / ~0.8`).
- **Recording indicator** — ambient closed-notch indicator during voice capture
  (not a drop-down).

**Reduce Motion (WCAG):** honor it — recede-to-glow dwell dismissal pauses on
hover; avoid motion-only signalling. Info dwell ~4s, actionable ~6s.

---

## 5. Iconography

**SF Symbols only** (Apple system set) — **not** Lucide. In use: `terminal.fill`
· `gear` · `macwindow` · `sparkles` · `server.rack` · `chevron.left/right/up/down`
· `checkmark.circle.fill` · `xmark.circle.fill` · `eye` · `archivebox` ·
`doc.on.clipboard` · `tray.full` · `clock.arrow.circlepath` · `magnifyingglass` ·
`bubble.left` · `arrow.up.circle.fill`. Weight `.medium`.

Agent **phase** indicators (WaitingForInput / WaitingForApproval / Running /
Idle) are **bespoke pixel `StatusIcon` vectors**, not SF Symbols — rendered in
SwiftUI, motion encodes the phase.

> In Figma, SF Symbols aren't a font — use neutral placeholder squares or import
> the symbols as assets; don't fake them with unrelated glyphs.

---

## 6. Component conventions (Figma "Components (V2)")

Faithful mirror of the app, bound to the token collection:
- **UsageBar** — Session / Weekly meter; threshold colors (red > 80 / yellow > 60
  / else agent tint); track `surface/bar-track`, height 4.
- **AgentBadge** — identity capsule; fill `surface/badge-fill-*`, text `agent/*`,
  9 · Semibold caps.
- **Pill/Allow · Pill/Deny** — Allow: `button/allow-fill` + black text; Deny:
  `button/deny-fill` + white text.
- **InstanceRow** — agent session row: status icon · title + folder · amber
  tool line · agent badge · Deny/Allow.
- **AlertRow** — identity dot · folder · mono command · outcome glyph
  (allowed/denied/timed-out) · time.
- **UnifiedCard** — Shelf card `176×110` r12, 5 kinds (text/link/file/image/color),
  idle fill white 4%, stroke `terminal/dimmer`.
- **FeedCard** — format-driven (`.text/.data/.list/.generic`), reuses the Shelf
  card chrome + GW-221 source-app footer.
- **TabButton / TabSelectionView** — open-notch header; selected = white 95% on a
  `surface/hover-row` capsule, unselected = white 45%.
- **StatusIcon** — agent phase (idle/input = 6pt dot; approval/processing =
  animated spinner).
- **ChatBubbles** — user (right, white 15% r18) · assistant (dot + markdown) ·
  ToolCallRow (status dot color).
- **SettingsRow** — grouped `Form` section: label + trailing control (Toggle /
  Picker / Slider). Native macOS controls here.
- **Buttons** — IconButton (24×24, borderless, hover `surface/hover-icon`) ·
  ActionButton (tinted pill, icon + label).

---

## 7. When to use what

- **Identity vs state:** agent color for *who* (badges, per-agent dots); terminal
  color for *what's happening* (ready/pending/error). Don't cross them.
- **Native vs drawn:** Settings uses native SwiftUI controls (Toggle/Picker/
  Slider in `Form`). The notch and its surfaces are custom-drawn on black.
- **Buttons:** `allow-fill` = primary/confirm; `deny-fill` = secondary/cancel;
  tinted ActionButton pill for a highlighted action; borderless IconButton for
  chrome.
- **Text ladder:** primary = body you read; secondary = supporting meta; tertiary
  = footers/timestamps; disabled = inert.
- **Density:** the notch is small — glyph/tint/fill over labels; put numbers in
  detail views, not compact rows. One code path for Claude + Codex.
- **Don't redesign the substrate:** windowing/animation/tabs (inherited notch
  base) are stable — extend, don't rebuild.
- **Settings composes differently:** §1–§6 describe a 640-wide drawn surface on
  black. Settings is a 700×600 `NavigationSplitView` that follows system
  light/dark. For sheets, rows, states, status and inline copy there, use **§8**.

---

## 8. Settings — surface composition

`macos-conventions.md` §5 answers *which control* (native `Form` /
`Toggle` / `Picker` / `Slider`, `NavigationSplitView`, searchable sidebar). This
section answers *how the surface is composed* — everything in Settings that
isn't a `Form` row. It **does not override §5**: native controls stay native,
and nothing here asks you to hand-roll one.

**The frame** (rewritten for PR #85 — the standalone 700×600
`NavigationSplitView` and its `SettingsWindowController` are gone). Settings is
now a pane inside the unified Ghostwire window: a 224pt sidebar whose **Settings**
disclosure lists the panes, and a content column that runs the **full remaining
width** with 28pt gutters. Every pane sits under one `WindowPaneHeader` — title
left, a single fixed-width action slot right — and gets `.formStyle(.grouped)`
from `WindowSettingsView`. **Every pane is a `Form`.**

**Settings is dark-only now.** The window forces `.darkAqua` and paints black
(`ShelfWindowController.swift`), so the §2 `state/` axis has no light arm in play
and the light values below are unused until a light surface exists again. The
notch's white-opacity ladder (`terminal/dim`, `dimmer`, `surface/*`,
`button/allow-fill`) still must not be carried in — it composites to 1.00:1 on a
light background, and that is the reason the ladder is notch-only, not a fact
about which appearance ships today.

### 8.1 Sheets

**Width ladder — three rungs, chosen by what the sheet contains:**

| Rung | Width | Height | Contains |
|---|---|---|---|
| **S** | `420` | intrinsic | one decision · ≤3 fields · no list |
| **M** | `520` | intrinsic | a form with sections, or a short list that won't scroll — **the default** |
| **L** | `600` | fixed | a list the user scans and compares row by row |

**The rule:** pick the rung by content, then check it against the parent. **No
sheet may exceed the parent window's width minus 100pt** (700 − 100 = 600). If
the content needs more, it isn't a sheet — see §8.6.

**Height is intrinsic unless the content scrolls.** A sheet that grows as a
`DisclosureGroup` opens is correct; a fixed height that leaves dead space at the
bottom is not. Fix the height only on rung **L**, where the list scrolls inside
it.

Today: `MCPAddServerSheet` 440 → **S (420)**, `MCPImportSheet` 520 → **M
(520)**, `MCPServerDetailView` 480 → not a sheet at all (§8.6). The three widths
were never a ladder; they were three independent guesses.

**Padding & rhythm.** `.padding(20)` on the sheet root; `spacing: 12` between
the top-level blocks (header · content · footnote · actions). All three sheets
already do this — it is the one thing they agree on. Keep it.

**Button bar** sits at the **bottom, trailing**, as the last child of the root
stack:
- Primary rightmost, `.keyboardShortcut(.defaultAction)`, disabled until valid.
- `Cancel` to its left, `.keyboardShortcut(.cancelAction)` — **always set it
  explicitly**; two of the three sheets do and one doesn't, so Esc behaves
  differently depending on which sheet you're in.
- Destructive action **leading**, separated by the `Spacer()`, `role:
  .destructive`. Never adjacent to the primary.
- Bulk-selection controls (`Select All`) go **leading**, with the destructive
  slot; they are not confirmations.
- A `Divider()` above the bar **only when the content above scrolls** — it
  terminates a scroll region. On an intrinsic-height sheet it is noise.

**Button title carries the count**, not the noun: `Add`, `Add 1 Server`,
`Add 3 Servers`. The user should be able to read the commit off the button
without re-counting the list.

### 8.2 List rows

**Anatomy** — leading to trailing, all optional except the title:

```
[ status affordance ] [ title            ] [ trailing meta ] [ badge ]
  8×8 dot | SF Symbol   13 · Medium         11 · caption      9–10 caps
  | checkbox            ────────────────    .secondary        r4 fill
                        [ secondary line ]
                         11 · caption
                        [ note line     ]
                         10 · caption2
```

- **Exactly one leading affordance.** A dot *and* a checkbox *and* a symbol is
  three encodings of two facts.
- **State dot is `8×8` in Settings**, not the notch's `6×6` (§3). At grouped-
  `Form` density, next to 13pt text and a mouse pointer rather than a glance
  target, 6 disappears. This is a deliberate divergence, not drift — every
  Settings dot already uses 8.
- **Badge:** `caption2.monospaced()`, `.padding(.horizontal, 5)`,
  `.padding(.vertical, 2)`, `RoundedRectangle(cornerRadius: 4)` filled
  `.quaternary`. Four badges exist today at r4/r3 and v2/v1 — **r4, h5/v2** is
  the one.
- **Density:** `.padding(.vertical, 2)` for a row inside a `Form` section;
  `.padding(.vertical, 3)` for a two-line row inside a `List`. Nothing else.

**The secondary line** exists only to say something the title cannot:
- **One line of state, one line of consequence, maximum.** A third line means
  the row wants to be a drill-in.
- **Never restate the badge or the trailing meta.** "3 tools" trailing and
  "Connected — 3 tools" beneath is one fact printed twice.
- **A non-default state MUST put its words here** if they don't fit on the title
  line (§8.4). A default state gets no secondary line at all — silence is the
  signal that nothing needs attention.
- Monospace it when it is a path, command or identifier the user might copy, and
  give it `.textSelection(.enabled)` + `.truncationMode(.middle)`.

**When a row is tappable:**
- **The whole row taps** → only if the tap **drills in**. Add
  `.contentShape(Rectangle())`.
- **The row carries its own control** (Toggle, checkbox, button) → the row taps
  to operate *that control* and nothing else. The control needs an
  `.accessibilityLabel`, because its meaning is otherwise position-only.
- **Never both.** A row that both drills in and toggles has no correct
  hit-testing.
- A row that can't be acted on is `.disabled` and `.secondary` — not hidden, and
  not tappable-with-no-effect.

### 8.3 Empty · loading · error · all-done

All four share **one shape**: a centered glyph (`.largeTitle`) over one sentence
(`.multilineTextAlignment(.center)`, `.secondary`), filling the content region
(`.frame(maxWidth: .infinity, maxHeight: .infinity)`). They are interchangeable
because they occupy the same slot — the only thing that varies is glyph, tint
and sentence.

| State | Glyph | Tint | The sentence says |
|---|---|---|---|
| **Empty** | the section's own icon | `.secondary` | **what this section is for** |
| **Loading** | `ProgressView()` | — | nothing |
| **Error** | `exclamationmark.triangle` | `state/error` failed · `state/attention` fixable | what failed, and the path or identifier |
| **All-done** | `checkmark.circle` | `state/ok` | what is now true |

**Empty states state the section's JOB, not its emptiness** (GW-367). "No tools
bound yet." tells the user nothing they can't see. "Bind a read-only tool and
its result shows up as a Feed card" makes the feature legible from a screen
containing zero items — no onboarding required. Ban the whole family: *No X yet*
· *Nothing here* · *0 items*. `MCPSettingsView.swift:66` is the model.

**Loading** only replaces a region that is *otherwise blank*, and only when the
wait exceeds ~200ms. Never spin over content that is already on screen — leave
it, or `.redacted`.

**All-done is a success, so say the success.** "Nothing can be added" reads as a
failure; "All 7 servers in your Claude Code config are already set up here"
reads as the reassurance it is.

**Error names the thing.** Include the file path, URL or server name, and make
it selectable. `state/error` when it broke; `state/attention` when the user can
fix it — the tint is the difference between "this is over" and "your move".

### 8.4 Status communication

Five states, one vocabulary. This is the Settings counterpart to the notch's
`terminal/` state tokens.

| State | Token | Glyph | Example |
|---|---|---|---|
| ok | `state/ok` | `checkmark.circle.fill` | Installed · Trusted · Connected |
| attention | `state/attention` | `exclamationmark.shield` · `exclamationmark.triangle.fill` | Not trusted yet · Needs authorization · Re-trust required |
| error | `state/error` | `xmark.circle.fill` | the failure reason, verbatim |
| pending | `state/pending` | `ProgressView` / `ellipsis.circle` | Connecting… |
| inert | `state/inert` | `circle` | Disconnected · Not detected |

**A state is never a bare dot.** Every non-default state pairs the color with
**words in the same row** — this is *never encode meaning by color alone*
(§2 above, `macos-conventions.md` §6) made concrete for Settings. A freshly
imported stdio server showing an
unlabelled grey dot reads as "the import failed"; the same dot with *"Not
trusted — open to review the command"* reads as an instruction
(`MCPSettingsView.swift:140-148`).

- **ok and inert may go wordless** *only* when an adjacent element already says
  it (a trailing "3 tools" is the words for `connected`).
- **attention and error never go wordless.** No exceptions.
- **VoiceOver:** the affordance's `.accessibilityLabel` **is the caption text**,
  never the color — `.accessibilityLabel("Not trusted — open to review the
  command")`, not `"orange dot"` (`MCPSettingsView.swift:135`).
- **A state the user can fix ships its remedy** next to it: the exact command,
  copyable, plus a copy button that flips to a checkmark for ~2s.

**Shape it as data, not view code.** `CmuxSocketStatusPresentation.Row`
(`severity` · `glyph` · `status` · `remedy`) is the pattern: a pure struct maps
runtime state → presentation, the view only renders it, and the mapping is
unit-testable. New status surfaces follow it.

### 8.5 Inline explanatory copy

Settings panes carry security and consequence notes ("stored in your Keychain",
"not trusted yet", "saved in plain text"). Three ranks — **use the highest one
that fits, never two ranks for the same fact**:

| Rank | Treatment | Scope |
|---|---|---|
| **Section footer** | `Form` footer · `.caption` · `.secondary` · **`.leadingFooter()`** | what the section does + its standing privacy/consequence line |
| **Row note** | `.caption2` · `.secondary` · under the row title | consequence scoped to *this* row |
| **Consequence warning** | `Label(_, systemImage:)` · `.caption` · **`state/attention`** | proceeding does something surprising or hard to undo |

- **`.leadingFooter()` is mandatory on every footer.** macOS grouped `Form`s
  trail-align the footer block, so help text reads ragged-left on the right
  edge. `SettingsModule.swift:103` exists for this; there is no case where you
  want the default.
- **Name the store, not the adjective.** "copied to your Keychain, not to
  Ghostwire's config file" · "saved in `~/.ghostwire/mcp-servers.json` in plain
  text". Never "stored securely" — that is a claim the user can't check.
- **One consequence warning per screen.** Two means the *design* is asking for
  too much trust in one step, and the fix is the flow, not the copy.
- **A consequence line never rides `.secondary` alone.** In light mode
  `.secondary` composites to 3.95:1 (§2) — below the 4.5:1 floor for the one
  line the user has to read to make a safe choice. Consequence copy takes
  `state/attention` or `.primary`.
- Warnings are **conditional**: show the "this runs a program on your Mac" line
  only once a local command is actually detected. A standing warning is
  wallpaper.

### 8.6 Sheet or drill-in

**The test: does this have a `Cancel` that means something?**

- **Yes → sheet.** A bounded task with a commit and an abandon, that returns you
  where you were. Nothing takes effect until the primary button.
- **No → drill-in.** A *place* with ongoing state you'll come back to — a
  server, an agent, a source. Edits apply as you make them; there is nothing to
  cancel, so there is no Cancel.

Drill-ins push into the detail column and come back via the navigation bar, not
a `Done` button. A `Done` that only dismisses is the tell that a drill-in has
been dressed as a modal.

`MCPServerDetailView` fails the test today: it is presented as `.sheet(item:)`,
its buttons are `Remove Server` / `Done`, and every control inside it — the
allowlist toggles, the feed bindings, the arguments field — writes through
immediately. It is a drill-in wearing a sheet. **Fixing it is GW-255's job, not
this section's** — recorded here so the next pane doesn't copy it.

**Never a sheet-over-a-sheet.** If a sheet needs to open something, it needs to
be a drill-in.

> **Notch panel constraint:** none of this applies to the notch. Settings sheets
> are safe because they are attached to an ordinary `NSWindow` — presenting any
> dialog while the notch panel is open deadlocks
> (`macos-conventions.md` §3). The Settings window is where modals live.

---

See also: [`macos-conventions.md`](./macos-conventions.md) for the AppKit/macOS
platform constraints, and the Figma file's **Foundations** / **Components (V2)**
pages for the visual reference. Skills: `ghostwire-codebase` (build gotchas),
`macos-development`, `macos-design-guidelines`, `swiftui-patterns`.
