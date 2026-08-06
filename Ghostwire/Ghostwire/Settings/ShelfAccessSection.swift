//
//  ShelfAccessSection.swift
//  Ghostwire
//
//  GW-173: the Agents-tab home for the MCP context-hub SERVER (pull side) —
//  the symmetric twin of hook installation. Hooks push agent events INTO the
//  notch; this lets agents PULL held context OUT of the Shelf. Both are
//  per-agent integration, so both live in the Agents tab and share the same
//  one-code-path row pattern (driven by MCPServeRegistration.targets()).
//
//  The master toggle is the consent gate: off → the server serves an empty
//  Shelf even if an agent is registered.
//

import AppKit
import Defaults
import SwiftUI

struct ShelfAccessSection: View {
    @Default(.mcpServeEnabled) private var enabled
    @ObservedObject private var shelf = ShelfStateViewModel.shared

    var body: some View {
        Section {
            Toggle("Let agents pull from your Shelf", isOn: $enabled)

            if enabled {
                ForEach(MCPServeRegistration.targets()) { target in
                    ShelfAccessRow(target: target)
                }

                HStack {
                    Text("Exposed")
                    Spacer()
                    Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Shelf access")
        } footer: {
            Text(
                "A local MCP server (`get_held_items`, `search_saves`, `get_item`). "
                + "Nothing is sent automatically — a held file, text, or link is shared "
                + "only when an agent calls a tool, and only the item requested."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// One agent's registration row. The app never writes the agent's config — it
/// shows the stdio entry (a `claude mcp add` command for Claude Code, a config
/// snippet for the rest) and the user adds it themselves.
private struct ShelfAccessRow: View {
    let target: MCPServeTarget

    @State private var copied = false

    private var buttonTitle: String {
        if copied { return "Copied" }
        switch target.method {
        case .command: return "Copy command"
        case .snippet: return "Copy config"
        }
    }

    private var payload: String {
        switch target.method {
        case .command(let command): return command
        case .snippet(let snippet): return snippet
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                Text(target.configPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(buttonTitle) { copy(payload) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
