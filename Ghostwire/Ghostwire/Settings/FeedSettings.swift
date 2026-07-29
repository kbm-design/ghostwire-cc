//
//  FeedSettings.swift
//  Ghostwire
//
//  GW-261 — the settings surface for the built-in feed Sources. The master
//  toggle lives in the sidebar (SettingsModule.feed, per the GW-144
//  convention); this pane owns which assets and which feeds.
//
//  Both built-in sources are keyless and permissionless by design, so they're
//  on by default — that's what lets a fresh install show a real feed instead of
//  an empty grid. Nothing here asks the user for an account or a token.
//

import Defaults
import SwiftUI

struct FeedSettings: View {
    @Default(.feedLocalStatsSourceEnabled) private var localStatsEnabled
    @Default(.feedCryptoSourceEnabled) private var cryptoEnabled
    @Default(.feedCryptoSymbols) private var symbols
    @Default(.feedRSSSourceEnabled) private var rssEnabled
    @Default(.feedRSSURLs) private var feedURLs
    @Default(.feedNotchVisibleCount) private var notchVisibleCount
    @Default(.feedMCPSourcesEnabled) private var mcpEnabled
    @Default(.feedMCPRefreshSeconds) private var mcpRefreshSeconds
    @Default(.feedRankingMode) private var rankingMode

    @State private var newSymbol = ""
    @State private var newFeedURL = ""
    @State private var urlError: String?

    var body: some View {
        Form {
            // Ghostwire's own numbers -----------------------------------------
            Section {
                Toggle("Ghostwire activity", isOn: $localStatsEnabled)
                    .tint(.effectiveAccent)
            } header: {
                Text("Local")
            } footer: {
                Text("Your Claude quota and how many agents are running, read from what Ghostwire already tracks. Nothing leaves this Mac. Cards are hidden when there's no data rather than showing zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // Crypto -----------------------------------------------------------
            Section {
                Toggle("Crypto prices", isOn: $cryptoEnabled)
                    .tint(.effectiveAccent)

                if cryptoEnabled {
                    ForEach(symbols, id: \.self) { symbol in
                        HStack {
                            Text(symbol)
                            Spacer()
                            Button {
                                symbols.removeAll { $0 == symbol }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("Add symbol (e.g. DOGE)", text: $newSymbol)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addSymbol)
                        Button("Add", action: addSymbol)
                            .disabled(normalizedSymbol.isEmpty)
                    }
                }
            } header: {
                Text("Crypto")
            } footer: {
                Text("Live prices from Hyperliquid's public API — no account or key. A symbol that isn't listed there is skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // RSS / Atom -------------------------------------------------------
            Section {
                Toggle("RSS & Atom feeds", isOn: $rssEnabled)
                    .tint(.effectiveAccent)

                if rssEnabled {
                    ForEach(feedURLs, id: \.self) { feed in
                        HStack {
                            Text(displayName(for: feed))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                feedURLs.removeAll { $0 == feed }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        TextField("Add feed URL", text: $newFeedURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addFeed)
                        Button("Add", action: addFeed)
                            .disabled(newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if let urlError {
                        Text(urlError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Feeds")
            } footer: {
                Text("Any RSS or Atom URL — a blog, a changelog, or a repo's releases feed (append /releases.atom to a GitHub repo URL). Each feed shows as one card listing its newest entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // MCP servers (GW-214) ---------------------------------------------
            Section {
                Toggle("MCP servers", isOn: $mcpEnabled)
                    .tint(.effectiveAccent)

                if mcpEnabled {
                    if boundTools.isEmpty {
                        Text("No tools bound yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(boundTools, id: \.self) { label in
                            Text(label).font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                    Stepper(
                        "Refresh every \(mcpRefreshSeconds / 60) min",
                        value: $mcpRefreshSeconds, in: 60...3600, step: 60
                    )
                }
            } header: {
                Text("Connected servers")
            } footer: {
                Text("Your own data — issues, builds, balances — from the MCP servers you've connected. Bind a tool in Settings › MCP: open a server, allow a read-only tool, then press the grid icon. Nothing polls until you do, and Ghostwire only ever calls tools you've allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
            }

            // Notch row --------------------------------------------------------
            Section {
                Stepper("Cards in the notch: \(notchVisibleCount)",
                        value: $notchVisibleCount, in: 0...20)

                Picker("Let cards move when", selection: $rankingMode) {
                    ForEach(FeedRankingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How many of the ordered cards mirror into the notch's row. The detached window always shows all of them, in your order — nothing below ever reorders it.")
                    Text(rankingMode.explanation)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .leadingFooter()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Feed")
        // Any change to the catalog restarts the loops so the feed reflects it
        // immediately rather than at the next poll.
        .onChange(of: localStatsEnabled) { restart() }
        .onChange(of: cryptoEnabled) { restart() }
        .onChange(of: symbols) { restart() }
        .onChange(of: rssEnabled) { restart() }
        .onChange(of: feedURLs) { restart() }
        .onChange(of: mcpEnabled) { restart() }
        .onChange(of: mcpRefreshSeconds) { restart() }
    }

    /// Read-only mirror of what's bound over in Settings › MCP. Bindings are
    /// edited there (next to the allowlist they depend on); this pane just makes
    /// them visible from the place the user goes to ask "what's in my feed?".
    private var boundTools: [String] {
        MCPClientService.shared.store.servers.flatMap { config in
            config.feedBindings.map { "\(config.name) · \($0.tool)" }
        }
    }

    private var normalizedSymbol: String {
        newSymbol.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private func addSymbol() {
        let symbol = normalizedSymbol
        guard !symbol.isEmpty, !symbols.contains(symbol) else { return }
        symbols.append(symbol)
        newSymbol = ""
    }

    private func addFeed() {
        let raw = newFeedURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // Require a real http(s) URL — a typo here would otherwise fail silently
        // inside the fetch loop where the user can't see it.
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            urlError = "Enter a full URL, starting with https://"
            return
        }
        urlError = nil
        guard !feedURLs.contains(url.absoluteString) else { return }
        feedURLs.append(url.absoluteString)
        newFeedURL = ""
    }

    /// Host + last path component reads better in a narrow row than a full URL.
    private func displayName(for feed: String) -> String {
        guard let url = URL(string: feed), let host = url.host else { return feed }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path
        return path.isEmpty || path == "/" ? trimmedHost : trimmedHost + path
    }

    private func restart() {
        FeedSourceCoordinator.shared.start()
    }
}
