import AppKit
import Defaults
import SwiftUI

struct ClaudeCodeSettings: View {
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var selectedSound = BuddiSettings.notificationSound
    @ObservedObject private var usageService = UsageService.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Claude Code Hooks")
                    Spacer()
                    if hooksInstalled {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Installed")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Install") {
                            HookInstaller.installIfNeeded()
                            hooksInstalled = HookInstaller.isInstalled()
                        }
                    }
                }
            } header: {
                Text("Integration")
            } footer: {
                Text("Forwards Claude Code events to Notch Command Center via Unix socket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sound", selection: $selectedSound) {
                    ForEach(NotificationSound.allCases, id: \.self) { sound in
                        Text(sound.rawValue).tag(sound)
                    }
                }
                .onChange(of: selectedSound) { _, newValue in
                    BuddiSettings.notificationSound = newValue
                    if let name = newValue.soundName {
                        NSSound(named: NSSound.Name(name))?.play()
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Plays when Claude finishes and is ready for input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Socket")
                    Spacer()
                    let active = FileManager.default.fileExists(atPath: "/tmp/notch.sock")
                    Circle()
                        .fill(active ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(active ? "Active" : "Inactive")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Usage tracking")
                    Spacer()
                    if usageService.isAvailable {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Connected")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not available")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                Text("OAuth login required for plan usage display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if FileManager.default.fileExists(atPath: "/Applications/cmux.app") {
                Section {
                    HStack {
                        Text("Socket Control Mode")
                        Spacer()
                        Text("Automation mode")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("cmux")
                } footer: {
                    Text("To send messages from Notch Command Center to cmux sessions, set Socket Control Mode to \"Automation mode\" in cmux Settings > Automation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            hooksInstalled = HookInstaller.isInstalled()
            selectedSound = BuddiSettings.notificationSound
        }
    }
}
