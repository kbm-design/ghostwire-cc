# Ghostwire (Notch Command Center) — agent build guide

Native macOS notch app. A **context-mobility companion**: observe + gate AI coding agents, hold context, surface ambiently — without leaving your flow. Forked from Buddi (boring.notch window/animation + Claude Island hook integration).

Full project context lives in the Obsidian vault: `keelo/projects/notch-command-center/` — **start with `CLAUDE.md` (living status) + `Roadmap research — synthesis & priorities.md`**. Roadmap is tracked in Linear team **GW** across 6 projects. This file is the build-time guide for coding agents working in this repo.

## Build & run
- **Build/run with the scheme, NOT a bare target:** `xcodebuild -scheme Ghostwire ...` (a bare `-target` fails with `no such module 'Defaults'` — the SPM products link via the scheme). Project: `Ghostwire.xcodeproj`.
- Non-sandboxed (needs Unix-socket + file access) → not Mac App Store; distributed via direct download / Homebrew.

## Architecture — where things live (under `Ghostwire/`)
- **Agent integration** — `Services/Hooks/` (`HookInstaller`, `CodexHookInstaller`, `HookSocketServer`), `Services/Session/` (`ClaudeSessionMonitor`, `AgentFileWatcher`, `JSONLInterruptWatcher`, `ConversationParser`, `ChatHistoryManager`), `Services/State/SessionStore.swift`, `Services/Tmux/` (incl. `ToolApprovalHandler`), `Services/Window/` (finder/focuser/Yabai), `Services/Shared/` (`UsageService`, `ProcessTreeBuilder`, `TerminalAppRegistry`).
- **Notch shell (inherited base)** — `components/Notch/` (`GhostwireSkyLightWindow`, `NotchShape`), `private/CGSSpace.swift`, `managers/NotchSpaceManager.swift`. Borderless `NSPanel` in a `CGSSpace` at high window level; the notch is a *drawn* shape. Don't redesign — extend.
- **Capability surfaces (inherited)** — `managers/` (Music/Calendar/Battery/Brightness/Volume/Webcam), `MediaControllers/` (per-app + `NowPlayingController`), and **`components/Shelf/`** — a hold-store of `ShelfItemKind = .file(bookmark)/.text/.link` with security-scoped bookmarks + persistence. The Shelf **is** the context hold-store the roadmap builds on.
- **UI** — `Ghostwire/UI/` (ChatView / InstanceRow / approval bar), `components/Tabs/`.

## Hook / approval contract
- Agents → lifecycle hooks → **Unix socket `/tmp/com.ghostwire.notch.sock`** (`HookSocketServer`) → `SessionStore` → notch UI. Approve/Deny writes the verdict back over the held socket (`hookSpecificOutput.decision.behavior` = allow/deny).
- **`PermissionRequest` carries no `tool_use_id`** → correlate via a cache keyed off the preceding `PreToolUse` (FIFO by sorted input). Headless `claude -p` never fires interactive `PermissionRequest`.
- Codex hooks mirror Claude's schema at `~/.codex/hooks.json` (no `SessionEnd`/`Notification`); needs a one-time `/hooks` trust per hook change. Codex transcripts/usage live at `~/.codex/sessions/**/rollout-*.jsonl` (different schema/path from Claude's `~/.claude/projects/**/*.jsonl`).
- ⚠️ **Mid-rename (GW-152):** the hook script + agent-tag env var are being renamed `buddi-hook.py`→`ghostwire-hook.py` / `BUDDI_*`→`GHOSTWIRE_*`; both names still appear in-tree. Match what's already there per file until the rename lands.

## Build principles (read before designing features)
- **Terminal support is TIERED — tmux/cmux are NEVER hard dependencies.** Baseline = plain/normal terminal (focus frontmost terminal, keystroke/paste injection). tmux adds pane targeting. cmux adds rich surface addressing (`CMUX_SURFACE_ID`, `surface.send_text`). **Build degraded-but-functional first;** cmux/tmux are progressive enhancement (applies to pane-targeting GW-162 + send-to-agent inject GW-164).
- **Local-first / privacy.** Observation, the Shelf store, and the MCP transport are local. Data crosses the wire only on an actual tool execution (the invoked content, to the agent the user chose; a local agent → nothing leaves). **Never narrate the user's activity to a cloud agent** to auto-pick tools — tool exposure is curated pinned plugins + a search fallback, not a context-aware router.
- **Moat ≠ the approval UI.** The approval/observe core is commoditized (xisland/notchi/agentnotch ship it). The wedge is context-mobility + ambient context-ranking + the agent/context layer. Don't over-invest in approval polish as if it were the differentiator.
- **License hygiene (reference repos in `../reference-repos/`):** **notchi & cmux are GPL** → read as a spec, reimplement clean-room, **do not copy their source**; interop with cmux only via its socket/CLI/env-var contracts. **PikoChan / CodeIsland / agentnotch are MIT** → borrow directly (agentnotch's `CGSSpace.swift` is MPL — keep its header). NCC is itself a GPL fork (via Buddi) — keep LICENSE/attribution intact.

## Conventions
- Match surrounding Swift style. The notch substrate (windowing/animation/tabs) is stable — changes for the agent surface live in `Ghostwire/Services` + `Ghostwire/UI` + the live-activity/tab insertion points. Build must stay clean; smoke-test agent flows in a real Claude Code + Codex session.
