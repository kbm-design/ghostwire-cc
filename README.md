<div align="center">
  <h1>Ghostwire</h1>
  <p>A macOS notch command center for AI coding agents.</p>
</div>

<div align="center">
  <video src="https://github.com/user-attachments/assets/3856b8c7-ca83-4672-b8d2-3c58ac65f2e9" autoplay loop muted playsinline width="100%"></video>
</div>

Ghostwire lives in your MacBook's notch and gives you one consistent surface to observe, gate, and hand context to Claude Code, Codex, and other AI coding agents — without leaving your flow.

---

## Features

### Agent Integration

- **Live session monitoring** — track multiple concurrent Claude Code / Codex sessions in real time
- **Permission approvals** — approve or deny tool executions directly from the notch; denials are always a person's decision, Ghostwire never manufactures one
- **Chat interface** — full conversation history with markdown rendering, send messages back to the agent
- **Interaction states** — approval prompts, multiple-choice questions, and plan reviews each render as their own bar, not just a generic yes/no
- **Usage tracking** — session and weekly utilization at a glance
- **Terminal support** — works with a plain terminal out of the box; tmux and cmux add pane targeting and richer send-to-agent, but neither is required
- **Auto-setup** — hooks install automatically on first launch

### Context & Access (Shelf)

- **Hold-store** — drag in files, snippets, and links; capture clipboard history
- **Send-to-agent** — one tap to inject anything held in the Shelf into the active agent session
- **MCP client** — connect Ghostwire out to external MCP servers through an allowlisted gateway
- **MCP server** — expose your held Shelf context read-only so agents can pull it themselves (off by default, opt in per the Agents tab)

### Notch Utility

- **Music player** — album art, playback controls, and audio visualizer
- **Calendar** — upcoming events at a glance
- **Battery** — status and charging indicator
- **HUD replacement** — custom volume and brightness overlays
- **Webcam preview** — quick mirror from the notch
- **Keyboard shortcuts** — customizable hotkeys

## Requirements

- macOS 15.0+ (Sequoia)
- MacBook with notch (or external display support)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and/or Codex installed

## Install

Download the latest `.dmg` from the [Releases page](https://github.com/kbm-design/ghostwire-cc/releases/latest) and drag Ghostwire.app to Applications.

Since Ghostwire isn't notarized through the Mac App Store's sandboxed distribution path, Gatekeeper will flag the first launch. Clear the quarantine flag before opening:

```bash
xattr -dr com.apple.quarantine /Applications/Ghostwire.app
```

A Homebrew cask is planned but not yet available.

## How It Works

```
Agent (Claude Code / Codex) → Hooks → Unix Socket → Ghostwire → Notch UI
```

Ghostwire registers hooks with the agent's CLI on launch. When the agent emits lifecycle events — tool use, permission requests, session start/end — the hooks forward them to Ghostwire over a Unix domain socket. Ghostwire never gates silently: if it's absent, broken, or can't render a request, the agent's own permission prompt still fires, exactly as if Ghostwire were never installed.

## Building from Source

1. Clone the repo
2. Open `Ghostwire.xcodeproj` in Xcode 16+
3. Build with the **`Ghostwire`** scheme (not a bare target) — SPM dependencies resolve automatically

## Acknowledgements

Ghostwire is built on top of open-source work by others:

- **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam — the notch UI framework Ghostwire is built upon. Music player, calendar, battery, HUD replacement, and the core notch rendering system all come from boring.notch.
- **[Claude Island](https://github.com/farouqaldori/claude-island)** by farouqaldori — Claude Code session monitoring, hook system, and the chat interface originate from Claude Island.

See [NOTICE](NOTICE) for full attribution and licensing details.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
