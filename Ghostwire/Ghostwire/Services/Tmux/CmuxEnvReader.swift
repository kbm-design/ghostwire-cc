//
//  CmuxEnvReader.swift
//  Ghostwire
//
//  GW-204: read a pane's cmux identity from process ENV, not screen text.
//
//  cmux sets CMUX_SURFACE_ID / CMUX_WORKSPACE_ID per pane; the agent process
//  (and everything below it) inherits them. A same-uid process's environment
//  is readable via sysctl KERN_PROCARGS2, so we walk from the agent PID up its
//  ancestor chain reading those vars and build the cmux target from the refs.
//
//  This replaces the old screen-content matcher (first pane whose visible text
//  contained the project folder name), which picked the wrong pane whenever
//  several worktrees of one repo were open. Verified 2026-06-04: the env value
//  equals `cmux --json identify`'s caller.surface_id, so an env read and a hook
//  ref agree on the same surface.
//
//  GPL hygiene: this interops with cmux only through its documented env-var
//  contract - no cmux source is used.
//

import Foundation

/// Reads cmux identity (workspace/surface refs) from process environment.
enum CmuxEnvReader {

    /// The env var cmux sets to the pane's surface ref.
    static let surfaceIdKey = "CMUX_SURFACE_ID"
    /// The env var cmux sets to the pane's workspace ref.
    static let workspaceIdKey = "CMUX_WORKSPACE_ID"

    // MARK: - Pure parsing seams (unit-tested)

    /// Parse the raw `KERN_PROCARGS2` buffer for a process into an environment
    /// dictionary.
    ///
    /// Layout (man 3 sysctl / Darwin convention):
    ///   - int32 argc (host byte order)
    ///   - exec_path (NUL-terminated), then NUL padding
    ///   - argc NUL-terminated argv strings
    ///   - NUL-terminated env strings ("KEY=VALUE"), up to the end of the buffer
    ///
    /// We skip argc + exec_path + argv, then read the remaining "KEY=VALUE"
    /// strings. Entries without '=' (or empty) are ignored.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String: String] {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return [:] }

        // argc, host byte order (reassemble from bytes; the buffer is not aligned)
        var rawArgc: UInt32 = 0
        for i in 0..<intSize {
            rawArgc |= UInt32(buffer[i]) << (8 * i)
        }
        let argc = Int(Int32(bitPattern: rawArgc))
        guard argc >= 0 else { return [:] }

        var index = intSize

        // exec_path, then any NUL padding before argv[0]
        index = skipCString(buffer, from: index)
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        // argv: argc NUL-terminated strings
        var consumed = 0
        while consumed < argc && index < buffer.count {
            index = skipCString(buffer, from: index)
            consumed += 1
        }

        // Everything remaining is the environment block.
        var env: [String: String] = [:]
        while index < buffer.count {
            let (entry, next) = readCString(buffer, from: index)
            index = next
            guard !entry.isEmpty else { continue }
            if let (key, value) = splitEnvEntry(entry) {
                env[key] = value
            }
        }

        return env
    }

    /// Build cmux workspace/surface refs from an environment dictionary.
    /// Returns nil unless BOTH vars are present and non-empty (a half-set env is
    /// not a usable target - mirror the hook-ref policy in `MultiplexerTargetResolver`).
    static func cmuxRefs(fromEnv env: [String: String]) -> (workspace: String, surface: String)? {
        guard let workspace = env[workspaceIdKey], !workspace.isEmpty,
              let surface = env[surfaceIdKey], !surface.isEmpty else {
            return nil
        }
        return (workspace, surface)
    }

    /// Build a cmux `TmuxTarget` directly from an environment dictionary.
    static func cmuxTarget(fromEnv env: [String: String]) -> TmuxTarget? {
        guard let refs = cmuxRefs(fromEnv: env) else { return nil }
        return .cmux(workspace: refs.workspace, surface: refs.surface)
    }

    // MARK: - sysctl read (not unit-testable against arbitrary PIDs; isolated)

    /// Read the environment of a same-uid process via `sysctl KERN_PROCARGS2`.
    /// Returns nil if the call fails (e.g. process gone, or owned by another uid).
    static func environment(forPid pid: Int) -> [String: String]? {
        guard let buffer = procArgsBuffer(forPid: pid) else { return nil }
        let env = parseProcArgs(buffer)
        return env.isEmpty ? nil : env
    }

    private static func procArgsBuffer(forPid pid: Int) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0

        // First call: discover the required buffer size.
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { ptr -> Int32 in
            sysctl(&mib, UInt32(mib.count), ptr.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }

        if size < buffer.count {
            buffer.removeLast(buffer.count - size)
        }
        return buffer
    }

    // MARK: - Byte helpers

    /// Advance past a NUL-terminated C string, returning the index just after the NUL.
    private static func skipCString(_ buffer: [UInt8], from start: Int) -> Int {
        var i = start
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        return i < buffer.count ? i + 1 : i
    }

    /// Read a NUL-terminated UTF-8 string, returning it plus the index after the NUL.
    private static func readCString(_ buffer: [UInt8], from start: Int) -> (String, Int) {
        var i = start
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        let str = String(decoding: buffer[start..<i], as: UTF8.self)
        let next = i < buffer.count ? i + 1 : i
        return (str, next)
    }

    /// Split "KEY=VALUE" on the first '='. Returns nil if there is no '=' or the
    /// key is empty.
    private static func splitEnvEntry(_ entry: String) -> (String, String)? {
        guard let eq = entry.firstIndex(of: "=") else { return nil }
        let key = String(entry[entry.startIndex..<eq])
        guard !key.isEmpty else { return nil }
        let value = String(entry[entry.index(after: eq)...])
        return (key, value)
    }
}
