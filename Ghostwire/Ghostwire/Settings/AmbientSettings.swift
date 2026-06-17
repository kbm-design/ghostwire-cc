//
//  AmbientSettings.swift
//  Ghostwire
//
//  GW-172 — the (minimal) settings surface for the Tier-0 ambient spine. The
//  master capture toggle lives in the sidebar (SettingsModule.ambient, per the
//  GW-144 convention); this pane owns retention, the app denylist, and the
//  delete-all affordance. Everything here is local — the privacy footer says so
//  plainly because honesty about capture is itself the trust feature.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct AmbientSettings: View {
    @Default(.ambientRetention) var retention
    @Default(.ambientAppDenylist) var denylist

    var body: some View {
        Form {
            // Retention --------------------------------------------------------
            Section {
                Picker("Keep activity for", selection: $retention) {
                    ForEach(AmbientRetention.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } header: {
                Text("Retention")
            } footer: {
                Text(retention == .sessionOnly
                    ? "Activity is kept in memory only and cleared when Ghostwire quits — nothing is written to disk."
                    : "Older activity is deleted automatically. Stored on this Mac, never sent anywhere.")
                    .leadingFooter()
            }

            // Excluded apps ----------------------------------------------------
            Section {
                if denylist.isEmpty {
                    Text("No apps excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(denylist, id: \.self) { bundleID in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.displayName(for: bundleID))
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                denylist.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop excluding \(Self.displayName(for: bundleID))")
                        }
                    }
                }
                Button("Add application…", action: addApplication)
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Time spent in these apps is never recorded. Password managers are excluded by default.")
                    .leadingFooter()
            }

            // Data -------------------------------------------------------------
            Section {
                Button("Delete all activity data", role: .destructive) {
                    ContextStore.shared.deleteAllData()
                }
            } footer: {
                Text("Removes every stored activity shard from this Mac.")
                    .leadingFooter()
            }
        }
        .navigationTitle("Activity")
    }

    // MARK: - Denylist editing

    /// Resolve a bundle ID to its app's display name, falling back to the ID when
    /// the app isn't installed/resolvable.
    private static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Pick an application and add its bundle ID to the denylist. Settings is a
    /// normal window (not the notch panel), so an NSOpenPanel is safe here.
    private func addApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !denylist.contains(bundleID) else { return }
        denylist.append(bundleID)
    }
}
