//
//  TmuxTargetFinder.swift
//  Ghostwire
//
//  Finds tmux/cmux targets for Claude processes
//

import Foundation

/// Finds tmux/cmux session/window/pane targets for Claude processes
actor TmuxTargetFinder {
    static let shared = TmuxTargetFinder()

    private init() {}

    /// Find the multiplexer target for a given Claude PID (tries tmux first, then cmux)
    func findTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        // Try tmux first
        if let tmuxTarget = await findTmuxTarget(forClaudePid: claudePid) {
            return tmuxTarget
        }

        // Fall back to cmux
        return await findCmuxTarget(forClaudePid: claudePid)
    }

    /// Find the multiplexer target for a given working directory.
    ///
    /// tmux can be matched by `#{pane_current_path}`, but cmux has no
    /// working-directory handle - its precise refs come from the pane env, which
    /// requires a PID. A bare working directory therefore resolves to tmux only;
    /// cmux callers must go through `findTarget(forClaudePid:)` (GW-204).
    func findTarget(forWorkingDirectory workingDir: String) async -> TmuxTarget? {
        await findTmuxTargetByDir(workingDir: workingDir)
    }

    /// Check if a session's pane is currently the active/focused pane
    func isSessionPaneActive(claudePid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Check tmux
        if ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree) {
            return await isTmuxPaneActive(claudePid: claudePid)
        }

        // Check cmux
        if ProcessTreeBuilder.shared.isInCmux(pid: claudePid, tree: tree) {
            return await isCmuxSurfaceActive(claudePid: claudePid)
        }

        return false
    }

    // MARK: - tmux Target Finding

    private func findTmuxTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runCommand(path: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
        ]) else {
            return nil
        }

        let tree = ProcessTreeBuilder.shared.buildTree()

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let panePid = Int(parts[1]) else { continue }

            let targetString = String(parts[0])

            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: panePid, tree: tree) {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    /// Find the tmux target whose pane tty matches. `tty` is stored without
    /// the /dev/ prefix (GW-162: moved here from ChatView - the precise
    /// tmux path, preferred over dir/PID heuristics)
    func findTarget(forTty tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runCommand(path: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"
        ]) else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let paneTty = String(parts[1]).replacingOccurrences(of: "/dev/", with: "")
            if paneTty == tty {
                return TmuxTarget(from: String(parts[0]))
            }
        }

        return nil
    }

    private func findTmuxTargetByDir(workingDir: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        guard let output = await runCommand(path: tmuxPath, args: [
            "list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}"
        ]) else {
            return nil
        }

        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let targetString = String(parts[0])
            let panePath = String(parts[1])

            if panePath == workingDir {
                return TmuxTarget(from: targetString)
            }
        }

        return nil
    }

    private func isTmuxPaneActive(claudePid: Int) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        guard let sessionTarget = await findTmuxTarget(forClaudePid: claudePid) else {
            return false
        }

        guard let output = await runCommand(path: tmuxPath, args: [
            "display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}"
        ]) else {
            return false
        }

        let activeTarget = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTarget.targetString == activeTarget
    }

    // MARK: - cmux Target Finding

    /// Find the cmux surface for a Claude PID by reading the pane's inherited
    /// env (GW-204). cmux exports CMUX_SURFACE_ID / CMUX_WORKSPACE_ID per pane;
    /// the agent process inherits them, so we walk from the agent PID up its
    /// ancestor chain reading `KERN_PROCARGS2` env until both refs are present.
    ///
    /// This replaces the old screen-content matcher (which picked the first pane
    /// whose visible text mentioned the project folder - wrong-pane roulette with
    /// parallel worktrees in one repo). No screen-content fallback.
    private func findCmuxTarget(forClaudePid claudePid: Int) async -> TmuxTarget? {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // Verify the Claude process is actually in cmux
        guard ProcessTreeBuilder.shared.isInCmux(pid: claudePid, tree: tree) else {
            return nil
        }

        // Walk PID -> ancestors; the pane env is inherited, so the nearest
        // ancestor that carries both refs wins.
        for pid in ProcessTreeBuilder.shared.ancestorChain(of: claudePid, tree: tree) {
            if let env = CmuxEnvReader.environment(forPid: pid),
               let target = CmuxEnvReader.cmuxTarget(fromEnv: env) {
                return target
            }
        }

        return nil
    }

    private func isCmuxSurfaceActive(claudePid: Int) async -> Bool {
        guard let cmuxPath = await TmuxPathFinder.shared.getCmuxPath() else {
            return false
        }

        guard let target = await findCmuxTarget(forClaudePid: claudePid) else {
            return false
        }

        // Get the currently focused surface
        guard let identifyOutput = await runCommand(path: cmuxPath, args: ["--json", "identify"]) else {
            return false
        }

        guard let data = identifyOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let focused = json["focused"] as? [String: Any],
              let focusedSurface = focused["surface_ref"] as? String else {
            return false
        }

        return target.cmuxSurfaceRef == focusedSurface
    }

    // MARK: - Common Helpers

    private func runCommand(path: String, args: [String]) async -> String? {
        do {
            return try await ProcessExecutor.shared.run(path, arguments: args)
        } catch {
            return nil
        }
    }
}
