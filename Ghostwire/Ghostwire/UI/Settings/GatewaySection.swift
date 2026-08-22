//
//  GatewaySection.swift
//  Ghostwire
//
//  GW-255 / GW-350 / GW-351: the gateway's real settings surface.
//
//  MOVED TO AGENTS (GW-449). It used to sit at the top of the MCP pane, on the
//  argument that the gateway's content IS the server list underneath it, so one
//  screen made that cause and effect legible. That argument survives; the
//  twenty rows it justified do not. Once the pane became a card GRID this block
//  filled the surface before a single connector was visible — an endpoint, a
//  copy command, a token and an explainer paragraph sitting on top of a browse
//  surface.
//
//  The whole thing lives here now, beside `ShelfAccessSection` — its sibling in
//  shape — where "what can agents reach?" is the question the pane already
//  answers. Connections says nothing about the gateway at all.
//
//  A one-line "Agents can reach N tools" summary was tried on Connections and
//  removed: the union of every connected server's `allowedTools` is a CEILING,
//  not what an agent sees, because GW-184's working set clips it. GW-451 owns
//  deciding what that surface should claim.
//
//  The trust posture is unchanged: the app never writes an agent's config. It
//  emits a command; the user runs it.
//

import AppKit
import Defaults
import SwiftUI

struct GatewaySection: View {
    @Default(.mcpGatewayEnabled) private var enabled
    @ObservedObject private var service = MCPClientService.shared

    @State private var isRunning = GatewayHTTPService.shared.isRunning
    @State private var registration: GatewayRegistrationAudit.Status = .notRegistered
    @State private var revealToken = false
    @State private var copied: String?

    /// Tools the gateway can actually reach — the union of every connected
    /// server's allowlist. This is the number that matters: the server count
    /// says nothing, because a connected server with an empty allowlist exposes
    /// nothing at all.
    private var exposedToolCount: Int {
        service.store.servers.reduce(0) { total, config in
            guard service.runtime(id: config.id)?.status.isConnected == true else { return total }
            return total + config.allowedTools.count
        }
    }

    private var hasServers: Bool { !service.store.servers.isEmpty }

    var body: some View {
        Section {
            Toggle("Let agents reach these servers", isOn: $enabled)
                .tint(.effectiveAccent)
                .onChange(of: enabled) { _, on in
                    Task { await setRunning(on) }
                }

            if enabled {
                statusRow
                if isRunning {
                    if case .stale(let scopes) = registration {
                        reconnectRow(scopes: scopes)
                    }
                    registrationRow
                    tokenRow
                }
            }
        } header: {
            Text("Gateway")
        } footer: {
            Text(
                "One local connector that re-exposes the servers below as a single set of tools. "
                + "Only tools you've allowed on each server are reachable — the gateway can't widen that."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .leadingFooter()
        }
        .task { await refresh() }
        .onChange(of: exposedToolCount) { _, _ in Task { await refresh() } }
    }

    // MARK: - Rows

    /// §8.4: ok and inert may go wordless only when something adjacent says it.
    /// Nothing else here says "running", so it takes words.
    @ViewBuilder private var statusRow: some View {
        let presentation = statusPresentation
        HStack(spacing: 8) {
            if presentation.severity == .pending {
                ProgressView().controlSize(.small).frame(width: 8, height: 8)
            } else {
                SettingsStateDot(severity: presentation.severity, caption: presentation.status)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.status)
                    .foregroundStyle(
                        presentation.severity == .attention
                            ? presentation.severity.color : Color.primary)
                if let remedy = presentation.remedy {
                    Text(remedy).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func reconnectRow(scopes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                "The token changed — re-connect to fix it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(SettingsStateColors.attention)

            // Name the scope. A stale PROJECT-scoped entry needs removing, not
            // re-adding — re-running the command writes a user-scoped one and
            // leaves the broken project entry in place (GW-350).
            Text(scopeExplanation(scopes))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var registrationRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code")
                Text(GatewayHTTPService.shared.endpointURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(copied == "command" ? "Copied" : "Copy command") {
                copy(
                    GatewayRegistration.claudeCommand(
                        endpointURL: GatewayHTTPService.shared.endpointURL,
                        token: GatewayHTTPService.shared.token),
                    tag: "command")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    /// The token is a shared secret the host already stores in plain text, so
    /// revealing it is not a new exposure — but it stays masked by default so a
    /// screenshot or a screen-share doesn't leak it by accident.
    private var tokenRow: some View {
        HStack {
            Text("Token")
            Spacer()
            // Selectable only once revealed — the two `textSelection` values
            // are different types, so this is a branch rather than a ternary.
            Group {
                if revealToken {
                    Text(GatewayHTTPService.shared.token).textSelection(.enabled)
                } else {
                    Text("••••••••••••")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                .buttonStyle(.borderless)
            Button(copied == "token" ? "Copied" : "Copy") {
                copy(GatewayHTTPService.shared.token, tag: "token")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status mapping

    /// Pure state → presentation, per §8.4. Kept as a computed value rather
    /// than branching inside the view so the wording lives in one place.
    private var statusPresentation:
        (severity: SettingsStateSeverity, status: String, remedy: String?) {
        if !hasServers {
            return (.inert, "Nothing to expose yet", "Add a server below and the gateway starts.")
        }
        if !isRunning {
            return (.pending, "Starting…", nil)
        }
        if exposedToolCount == 0 {
            return (
                .attention, "Running — no tools exposed",
                "Open a server below and allow the tools you want agents to reach."
            )
        }
        return (
            .ok, "Running — \(exposedToolCount) tool\(exposedToolCount == 1 ? "" : "s") exposed",
            nil
        )
    }

    private func scopeExplanation(_ scopes: [String]) -> String {
        let projectScopes = scopes.filter { $0 != GatewayRegistrationAudit.userScopeLabel }
        guard !projectScopes.isEmpty else {
            return "Copy the command below and run it again."
        }
        let list = projectScopes.joined(separator: ", ")
        return "Copy the command below and run it again. There's also a project-scoped "
            + "registration in \(list) — remove that one with "
            + "`claude mcp remove \(GatewayRegistration.serverName)` from that directory, "
            + "or it will keep failing."
    }

    // MARK: - Actions

    private func setRunning(_ on: Bool) async {
        if on {
            await GatewayHTTPService.shared.start()
        } else {
            await GatewayHTTPService.shared.stop()
        }
        await refresh()
    }

    private func refresh() async {
        isRunning = GatewayHTTPService.shared.isRunning
        // Only meaningful once the listener is up: before that the live token
        // is still whatever the store hands back, and comparing it would flag
        // a perfectly good registration as stale mid-launch.
        registration = isRunning
            ? GatewayRegistrationAudit.status(liveToken: GatewayHTTPService.shared.token)
            : .notRegistered
    }

    private func copy(_ string: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copied == tag { copied = nil }
        }
    }
}
