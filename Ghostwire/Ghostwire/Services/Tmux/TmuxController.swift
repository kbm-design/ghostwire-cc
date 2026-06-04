//
//  TmuxController.swift
//  Ghostwire
//
//  High-level tmux operations controller
//

import Foundation

/// Controller for tmux operations
actor TmuxController {
    static let shared = TmuxController()

    private init() {}

    func findTmuxTarget(forClaudePid pid: Int) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forClaudePid: pid)
    }

    func findTmuxTarget(forWorkingDirectory dir: String) async -> TmuxTarget? {
        await TmuxTargetFinder.shared.findTarget(forWorkingDirectory: dir)
    }

    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.sendMessage(message, to: target)
    }

    func approveOnce(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveOnce(target: target)
    }

    func approveAlways(target: TmuxTarget) async -> Bool {
        await ToolApprovalHandler.shared.approveAlways(target: target)
    }

    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        await ToolApprovalHandler.shared.reject(target: target, message: message)
    }

    func switchToPane(target: TmuxTarget) async -> Bool {
        switch target.multiplexer {
        case .tmux:
            return await switchToTmuxPane(target: target)
        case .cmux:
            return await switchToCmuxSurface(target: target)
        }
    }

    private func switchToTmuxPane(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        do {
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-window", "-t", "\(target.session):\(target.window)"
            ])

            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "select-pane", "-t", target.targetString
            ])

            return true
        } catch {
            return false
        }
    }

    /// GW-162: the focus command sequence for a cmux surface. `tab-action
    /// --action select` (the old verb) does not exist in the cmux contract -
    /// `focus-panel` is "surface focus" and accepts surface refs directly.
    /// When cmux runs with `socketControlMode: "password"`, every command
    /// needs the `--password` global flag - same contract as the send path
    /// in `ToolApprovalHandler`.
    nonisolated static func cmuxFocusCommands(workspace: String, surface: String, password: String? = nil) -> [[String]] {
        let commands: [[String]] = [
            ["select-workspace", "--workspace", workspace],
            ["focus-panel", "--panel", surface, "--workspace", workspace],
        ]
        guard let password else { return commands }
        return commands.map { ["--password", password] + $0 }
    }

    private func switchToCmuxSurface(target: TmuxTarget) async -> Bool {
        guard let cmuxPath = await TmuxPathFinder.shared.getCmuxPath() else {
            return false
        }

        guard let workspace = target.cmuxWorkspaceRef,
              let surface = target.cmuxSurfaceRef else {
            return false
        }

        let password = CmuxAccessProbe.readConfig().socketPassword

        do {
            for arguments in Self.cmuxFocusCommands(workspace: workspace, surface: surface, password: password) {
                _ = try await ProcessExecutor.shared.run(cmuxPath, arguments: arguments)
            }
            return true
        } catch {
            return false
        }
    }
}
