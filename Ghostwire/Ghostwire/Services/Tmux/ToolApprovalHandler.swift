//
//  ToolApprovalHandler.swift
//  Ghostwire
//
//  Handles Claude tool approval operations via tmux
//

import Foundation
import os

/// Handles tool approval and rejection for Claude instances
actor ToolApprovalHandler {
    static let shared = ToolApprovalHandler()

    /// Logger for tool approval (nonisolated static for cross-context access)
    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "Approval")

    private init() {}

    /// Approve a tool once (sends '1' + Enter)
    func approveOnce(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "1", pressEnter: true)
    }

    /// Approve a tool always (sends '2' + Enter)
    func approveAlways(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "2", pressEnter: true)
    }

    /// Codex native approval menu, approve once. Default keymap: 'y' ("Yes,
    /// proceed"), acts immediately — no Enter (codex-rs tui/keymap.rs
    /// defaults; user-remappable, in which case this misses and the human
    /// answers at the prompt themselves). Terminal-first tier only: callers
    /// must have verified the gate is `.terminalFirst` (native menu live).
    func codexApproveNative(target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: "y", pressEnter: false)
    }

    /// Codex native approval menu, deny. The live menu binds "No, and tell
    /// Codex what to do differently" to **Esc** (observed on codex-cli
    /// 0.146.1; 'n' is not offered), so this sends the named Escape key,
    /// not a literal character. Same terminal-first caveats as
    /// `codexApproveNative`.
    func codexDenyNative(target: TmuxTarget) async -> Bool {
        await sendEscapeKey(to: target)
    }

    /// Send the named Escape key (not literal text) to a pane.
    private func sendEscapeKey(to target: TmuxTarget) async -> Bool {
        switch target.multiplexer {
        case .tmux:
            guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
            do {
                _ = try await ProcessExecutor.shared.run(
                    tmuxPath, arguments: ["send-keys", "-t", target.targetString, "Escape"])
                return true
            } catch {
                Self.logger.error("tmux escape error: \(error.localizedDescription, privacy: .public)")
                return false
            }
        case .cmux:
            guard let cmuxPath = await TmuxPathFinder.shared.getCmuxPath(),
                  let workspace = target.cmuxWorkspaceRef,
                  let surface = target.cmuxSurfaceRef else { return false }
            let password = Self.readCmuxSocketPassword()
            let base = ["send-key", "--workspace", workspace, "--surface", surface, "escape"]
            do {
                _ = try await ProcessExecutor.shared.run(
                    cmuxPath, arguments: password != nil ? ["--password", password!] + base : base)
                return true
            } catch {
                Self.logger.error("cmux escape error: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Reject a tool with optional message
    func reject(target: TmuxTarget, message: String? = nil) async -> Bool {
        // First send 'n' + Enter to reject
        guard await sendKeys(to: target, keys: "n", pressEnter: true) else {
            return false
        }

        // If there's a message, send it after a brief delay
        if let message = message, !message.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            return await sendKeys(to: target, keys: message, pressEnter: true)
        }

        return true
    }

    /// Send a message to a tmux target
    func sendMessage(_ message: String, to target: TmuxTarget) async -> Bool {
        await sendKeys(to: target, keys: message, pressEnter: true)
    }

    /// GW-164: land text in the target's input without auto-submitting.
    /// The chat send path (`sendMessage`) always presses Enter; send-to-agent
    /// defaults to *not* submitting (safety — the human reviews then sends),
    /// so the multiplexer tiers of `AgentInjectionService` route through here
    /// rather than re-implementing the cmux/tmux + password send contract.
    func sendText(_ text: String, to target: TmuxTarget, submit: Bool) async -> Bool {
        await sendKeys(to: target, keys: text, pressEnter: submit)
    }

    // MARK: - Private Methods

    private func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        switch target.multiplexer {
        case .tmux:
            return await sendTmuxKeys(to: target, keys: keys, pressEnter: pressEnter)
        case .cmux:
            return await sendCmuxKeys(to: target, keys: keys, pressEnter: pressEnter)
        }
    }

    private func sendTmuxKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return false
        }

        // tmux send-keys needs literal text and Enter as separate arguments
        // Use -l flag to send keys literally (prevents interpreting special chars)
        let targetStr = target.targetString
        let textArgs = ["send-keys", "-t", targetStr, "-l", keys]

        do {
            Self.logger.debug("Sending text to tmux \(targetStr, privacy: .public)")
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: textArgs)

            // Send Enter as a separate command if needed
            if pressEnter {
                Self.logger.debug("Sending Enter key to tmux")
                let enterArgs = ["send-keys", "-t", targetStr, "Enter"]
                _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: enterArgs)
            }
            return true
        } catch {
            Self.logger.error("tmux error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sendCmuxKeys(to target: TmuxTarget, keys: String, pressEnter: Bool) async -> Bool {
        guard let cmuxPath = await TmuxPathFinder.shared.getCmuxPath() else {
            return false
        }

        guard let workspace = target.cmuxWorkspaceRef,
              let surface = target.cmuxSurfaceRef else {
            Self.logger.error("Invalid cmux target: missing workspace or surface ref")
            return false
        }

        let password = Self.readCmuxSocketPassword()

        do {
            Self.logger.debug("Sending text to cmux \(surface, privacy: .public)")
            let sendArgs = password != nil
                ? ["--password", password!, "send", "--workspace", workspace, "--surface", surface, keys]
                : ["send", "--workspace", workspace, "--surface", surface, keys]
            _ = try await ProcessExecutor.shared.run(cmuxPath, arguments: sendArgs)

            if pressEnter {
                Self.logger.debug("Sending Enter key to cmux")
                let keyArgs = password != nil
                    ? ["--password", password!, "send-key", "--workspace", workspace, "--surface", surface, "return"]
                    : ["send-key", "--workspace", workspace, "--surface", surface, "return"]
                _ = try await ProcessExecutor.shared.run(cmuxPath, arguments: keyArgs)
            }
            return true
        } catch {
            Self.logger.error("cmux error: \(error.localizedDescription, privacy: .public). Set cmux socket mode to 'Automation' in cmux Settings to allow Ghostwire access.")
            return false
        }
    }

    /// GW-162: the socket password lives in cmux.json
    /// (automation.socketPassword) - the old read targeted a
    /// "socket-control-password" file cmux never writes
    private static func readCmuxSocketPassword() -> String? {
        CmuxAccessProbe.readConfig().socketPassword
    }
}
