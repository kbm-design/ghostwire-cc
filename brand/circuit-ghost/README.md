# Ghostwire brand — circuit-ghost

The app mark: a peach→pink ghost (agent identity, `agent/claude` tint) on a dark
circuit-board field. Source of truth for the Ghostwire icon and favicons.

- **`circuit-ghost.svg`** — the editable vector source. Edit this, then re-render
  everything below from it.
- **`AppIcon.appiconset/`** (in `Ghostwire/Assets.xcassets/`) — the macOS app icon,
  rendered from the SVG at the 10 required sizes.
- **`favicon/`** — the web favicon set (`favicon.ico` + `favicon-16/32/48/512.png`
  + `apple-touch-icon.png`). `favicon-512.png` is byte-identical to
  `icon_512x512.png`, so the web icon and the app icon stay in sync.
- **`preview-512.png`** — a standalone preview.

Keep the palette aligned with `docs/design-system.md` (`agent/claude` peach, dark
`surface/notch-bg`). If you re-render, replace both the appiconset PNGs and the
favicon set so they don't drift.
