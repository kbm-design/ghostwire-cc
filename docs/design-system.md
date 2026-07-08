# Ghostwire — Design System

The single source of truth for building Ghostwire's UI consistently. Mirrors the
Figma **Foundations** page (fileKey `tgXXJAGWxqrojUNY7Hvroh`, "Ghostwire (dark)"
token collection) and adds the **motion** language, which lives only in code.

**Dark-only.** The notch is a *drawn shape on pure black* and has no light
variant. The **Settings window is the one surface that follows system
light/dark** — design both there, dark everywhere else.

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

**Accessibility:** never encode meaning by color alone — read-only / destructive
badges pair the color with a text label. Honor the ability spectrum (screen
reader labels on dots/meters; contrast on the white-opacity ladder).

---

## 3. Spacing & shape

**Spacing scale (itemSpacing / padding, px):** `2 · 4 · 6 · 8 · 10 · 12 · 14 · 16`.

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

---

See also: [`macos-conventions.md`](./macos-conventions.md) for the AppKit/macOS
platform constraints, and the Figma file's **Foundations** / **Components (V2)**
pages for the visual reference. Skills: `ghostwire-codebase` (build gotchas),
`macos-development`, `macos-design-guidelines`, `swiftui-patterns`.
