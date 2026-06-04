//
//  CmuxAccessProbe.swift
//  Ghostwire
//
//  GW-162: classifies whether Ghostwire can drive the cmux control socket.
//  Ghostwire runs OUTSIDE cmux's process tree, so with the default
//  automation.socketControlMode = "cmuxOnly" the server accepts the
//  connection and immediately drops it (client sees EPIPE, exit 1). The
//  probe turns that silent failure into an actionable state the UI can
//  explain (set the mode / restart cmux / launch cmux).
//
//  Verified against cmux 0.64.x (2026-06-04): socket mode is read at app
//  launch only - the cmux.json file watcher and `reload-config` do NOT
//  re-arm the listener. So "config says an open mode but the server still
//  rejects us" specifically means: restart cmux.
//

import Foundation

/// What Ghostwire can do with the cmux control socket right now
enum CmuxSocketAccess: Equatable, Sendable {
    /// Control commands work
    case ok
    /// Server rejects external clients. `needsRestart` when the on-disk
    /// config already names an open mode (the running server just hasn't
    /// applied it); otherwise the user must change the mode first.
    case closedByPolicy(configuredMode: String?, needsRestart: Bool)
    /// CLI exists but no socket - cmux app isn't running
    case notRunning
    /// cmux CLI not installed
    case unavailable
}

enum CmuxAccessProbe {

    /// Values of automation.socketControlMode that admit external local
    /// clients (same-user processes outside cmux's own tree), per the cmux
    /// settings schema. "password" is excluded: it admits external clients
    /// only with credentials, so a rejection under it is not fixed by a
    /// restart.
    private static let openModes: Set<String> = [
        "automation", "allowAll", "openAccess", "fullOpenAccess", "full"
    ]

    /// Pure classification - all I/O results passed in (testable)
    static func classify(
        pingSucceeded: Bool,
        socketExists: Bool,
        cliInstalled: Bool,
        configuredMode: String?
    ) -> CmuxSocketAccess {
        guard cliInstalled else { return .unavailable }
        if pingSucceeded { return .ok }
        guard socketExists else { return .notRunning }
        let needsRestart = configuredMode.map { openModes.contains($0) } ?? false
        return .closedByPolicy(configuredMode: configuredMode, needsRestart: needsRestart)
    }

    // MARK: - cmux.json (JSONC) parsing

    struct Config: Equatable, Sendable {
        var socketControlMode: String?
        var socketPassword: String?
    }

    /// Parse the automation section out of cmux.json. The file is JSONC:
    /// // line comments (the shipped template is ~260 commented lines) and
    /// trailing commas are legal. Comment markers inside string literals
    /// ("https://...") must survive. Malformed input yields an empty config.
    static func parseConfig(_ jsonc: String) -> Config {
        let stripped = stripJSONC(jsonc)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let automation = json["automation"] as? [String: Any] else {
            return Config()
        }
        let mode = automation["socketControlMode"] as? String
        let rawPassword = automation["socketPassword"] as? String
        let password = (rawPassword?.isEmpty ?? true) ? nil : rawPassword
        return Config(socketControlMode: mode, socketPassword: password)
    }

    /// Remove // line comments (string-aware) and trailing commas so
    /// JSONSerialization can parse the remainder.
    private static func stripJSONC(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var chars = text.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }

        while let c = next() {
            if inString {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                continue
            }
            if c == "/" {
                if let lookahead = chars.next() {
                    if lookahead == "/" {
                        // line comment: drop to end of line, keep the newline
                        while let skipped = chars.next() {
                            if skipped == "\n" { result.append(skipped); break }
                        }
                        continue
                    }
                    pending = lookahead
                }
            }
            result.append(c)
        }

        // Trailing commas: ",  }" / ",\n]" -> "}" / "]"
        return result.replacingOccurrences(
            of: ",(\\s*[}\\]])",
            with: "$1",
            options: .regularExpression
        )
    }

    // MARK: - Live probing (I/O glue around the pure parts)

    /// Default locations, overridable for future testability
    static let socketPath = ("~/Library/Application Support/cmux/cmux.sock" as NSString).expandingTildeInPath
    static let configPath = ("~/.config/cmux/cmux.json" as NSString).expandingTildeInPath

    /// Run a live probe: `cmux ping` + socket/config reads -> classification
    static func probe() async -> CmuxSocketAccess {
        guard let cmuxPath = await TmuxPathFinder.shared.getCmuxPath() else {
            return classify(pingSucceeded: false, socketExists: false, cliInstalled: false, configuredMode: nil)
        }
        let pingSucceeded = (try? await ProcessExecutor.shared.run(cmuxPath, arguments: ["ping"])) != nil
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let configuredMode = readConfig().socketControlMode
        return classify(
            pingSucceeded: pingSucceeded,
            socketExists: socketExists,
            cliInstalled: true,
            configuredMode: configuredMode
        )
    }

    /// Read and parse the on-disk cmux.json (empty config if absent)
    static func readConfig() -> Config {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return Config()
        }
        return parseConfig(text)
    }
}
