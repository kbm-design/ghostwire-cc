//
//  LoginShellPATHResolver.swift
//  Ghostwire
//
//  GW-219: GUI apps inherit launchd's PATH, so bare `npx`/`uvx` server
//  commands fail with ENOENT. Resolve the user's login-shell PATH once
//  ($SHELL -ilc 'echo $PATH') and resolve commands to absolute paths at
//  add-time. The #1 practical hazard per the T6 research.
//

import Foundation

actor LoginShellPATHResolver {
    static let shared = LoginShellPATHResolver()

    private var cachedPATH: String?

    /// Fallback when the shell can't be queried (always appended as a safety net).
    private static let standardFallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func loginShellPATH() async -> String {
        if let cachedPATH { return cachedPATH }
        let shellPATH = Self.queryShellPATH()
        let processPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // Merge, de-dup, preserve order: shell first, then process env, then fallback.
        var components: [String] = shellPATH.split(separator: ":").map(String.init)
        components += processPATH.split(separator: ":").map(String.init)
        components += Self.standardFallback.split(separator: ":").map(String.init)
        var seen = Set<String>()
        let merged = components.filter { seen.insert($0).inserted }.joined(separator: ":")
        cachedPATH = merged
        return merged
    }

    /// Resolve a command name to an absolute executable path on `searchPath`.
    /// Pure + synchronous for testability.
    static func resolve(command: String, searchPath: String) -> String? {
        let fileManager = FileManager.default
        if command.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in searchPath.split(separator: ":") {
            let candidate = String(dir) + "/" + command
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Convenience: resolve against the cached login-shell PATH.
    func resolve(command: String) async -> String? {
        Self.resolve(command: command, searchPath: await loginShellPATH())
    }

    private static func queryShellPATH() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // swallow login noise

        do {
            try process.run()
        } catch {
            return ""
        }
        // Bounded wait: a hung dotfile must not hang Ghostwire.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
