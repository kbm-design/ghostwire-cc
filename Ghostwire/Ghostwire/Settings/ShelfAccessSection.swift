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
                + "Agents receive a held file, text, or link only when they call a tool — "
                + "nothing is sent automatically, and it never leaves your machine."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// One agent's registration row. Claude Code can be registered in place (it has
/// a CLI); the rest expose a copyable config snippet.
private struct ShelfAccessRow: View {
    let target: MCPServeTarget

    @State private var status: Status = .idle
    @State private var copied = false

    private enum Status: Equatable {
        case idle, working, done(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.displayName)
                    Text(target.configPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            statusLine
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var action: some View {
        switch target.method {
        case .cli:
            HStack(spacing: 8) {
                Button("Copy command") { copyCommand() }
                    .buttonStyle(.borderless)
                Button {
                    register()
                } label: {
                    if status == .working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Register")
                    }
                }
                .disabled(status == .working)
            }
        case .snippet(let snippet):
            Button(copied ? "Copied" : "Copy config") {
                copy(snippet)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .done(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green).lineLimit(2)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(3)
        default:
            EmptyView()
        }
    }

    private func register() {
        guard case .cli = target.method else { return }
        status = .working
        Task {
            do {
                let output = try await MCPServeRegistration.registerWithClaude()
                await MainActor.run { status = .done(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch {
                await MainActor.run { status = .failed(error.localizedDescription) }
            }
        }
    }

    private func copyCommand() {
        guard case .cli = target.method else { return }
        copy(MCPServeRegistration.claudeCommandString(executable: MCPServeRegistration.executablePath))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
