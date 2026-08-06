//
//  AgentInjectionService.swift
//  Ghostwire
//
//  GW-164 (C): the one path content takes to reach an agent's input.
//
//  Generalizes the chat send machinery (ChatView -> TmuxController.sendMessage
//  -> ToolApprovalHandler.sendCmuxKeys/send-keys) into a reusable injector that
//  every send-to-agent input type flows through. The chat input bar always
//  submits (presses Enter); send-to-agent defaults to landing the text WITHOUT
//  submitting so the human reviews and presses Enter (safety) — hence the
//  `submit:` flag.
//
//  TIERED (AGENTS.md): baseline must work.
//    - cmux:     surface send via the cmux CLI contract (+ --password)   [enhancement]
//    - tmux:     send-keys -l (+ Enter only when submit)                 [enhancement]
//    - baseline: focus the session's terminal, then pasteboard + ⌘V      [required]
//  The mux tiers reuse `ToolApprovalHandler.sendText` so the cmux/tmux +
//  password contract lives in exactly one place.
//
//  Files are injected as a PATH REFERENCE, not raw bytes: the agent reads the
//  file itself. Claude and Codex both accept `@<path>` in their input; the path
//  is made relative to the session cwd when it lives under it (else absolute),
//  and shell-quoted when it contains spaces.
//
//  GPL hygiene: cmux interop is via its documented CLI/env contract only.
//

import AppKit
import Foundation
import os

/// Per-agent input differences. Today Claude and Codex share the `@path`
/// file-reference convention; isolating it here keeps the one place a future
/// agent's quirks would land instead of branching through the send path.
enum AgentAdapter: Equatable, Sendable {
    case claude
    case codex

    /// Map a session's agent tag ("claude" | "codex" | …) to an adapter.
    /// Unknown/!nil tags fall back to the Claude convention (the shared `@path`
    /// form), which is also what Codex uses.
    static func forAgentTag(_ tag: String?) -> AgentAdapter {
        switch tag?.lowercased() {
        case "codex":
            return .codex
        default:
            return .claude
        }
    }

    /// How this agent references a file in its input. Both supported agents use
    /// the `@<path>` form; kept on the adapter so it is the single seam to vary.
    func fileReferenceToken(forPath path: String) -> String {
        "@\(path)"
    }
}

actor AgentInjectionService {
    static let shared = AgentInjectionService()

    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "Injection")

    private init() {}

    /// Why an injection couldn't be delivered (drives caller-side messaging).
    enum InjectionError: Error, Equatable, Sendable {
        /// The session's pane isn't addressable and the baseline focus/paste
        /// path also couldn't run (no pid to focus, accessibility denied, …).
        case noDeliverablePath
        /// The resolved send (mux tier) failed — pane closed, cmux socket
        /// policy, etc.
        case sendFailed
    }

    // MARK: - Public API

    /// Inject text into a session's input. Does NOT press Enter unless
    /// `submit` is true — by default the text is left for the human to send.
    @discardableResult
    func inject(text: String, into session: SessionState, submit: Bool = false) async -> Result<Void, InjectionError> {
        let resolution = MultiplexerTargetResolver.resolve(session: session)
        switch resolution {
        case .cmux(let workspace, let surface):
            let ok = await ToolApprovalHandler.shared.sendText(
                text, to: .cmux(workspace: workspace, surface: surface), submit: submit
            )
            return ok ? .success(()) : .failure(.sendFailed)

        case .tmuxTty(let tty):
            guard let target = await TmuxTargetFinder.shared.findTarget(forTty: tty) else {
                return .failure(.sendFailed)
            }
            let ok = await ToolApprovalHandler.shared.sendText(text, to: target, submit: submit)
            return ok ? .success(()) : .failure(.sendFailed)

        case .unresolvable:
            // Baseline tier: no multiplexer to address — focus the terminal and
            // paste. This is the path that must always work (AGENTS.md).
            return await injectViaBaseline(text: text, into: session, submit: submit)
        }
    }

    /// Inject a reference to a file into a session's input as `@<path>`
    /// (relative to the session cwd when under it, else absolute; shell-quoted
    /// when it contains spaces). The agent reads the file itself — no bytes are
    /// sent. Does NOT submit unless `submit` is true.
    @discardableResult
    func inject(file url: URL, into session: SessionState, submit: Bool = false) async -> Result<Void, InjectionError> {
        let adapter = AgentAdapter.forAgentTag(session.agent)
        let token = Self.fileReferenceToken(for: url, sessionCwd: session.cwd, adapter: adapter)
        return await inject(text: token, into: session, submit: submit)
    }

    // MARK: - Pure seams (unit-tested)

    /// Build the agent-input token for a file reference.
    /// - relative to `sessionCwd` when the file lives under it, else absolute
    /// - shell-quoted (single quotes) when the path contains whitespace
    /// - prefixed with the agent's reference sigil (`@`)
    nonisolated static func fileReferenceToken(
        for url: URL,
        sessionCwd: String,
        adapter: AgentAdapter
    ) -> String {
        let path = relativePath(forFile: url.path, underCwd: sessionCwd)
        return adapter.fileReferenceToken(forPath: shellQuoteIfNeeded(path))
    }

    /// The path to embed: relative to `cwd` when the file is inside the cwd
    /// subtree, otherwise the absolute path. A file that merely shares a prefix
    /// string with the cwd (e.g. `/a/project-2` vs cwd `/a/project`) is NOT
    /// treated as inside — we require a true path-component boundary.
    nonisolated static func relativePath(forFile filePath: String, underCwd cwd: String) -> String {
        let fileComponents = standardizedComponents(filePath)
        let cwdComponents = standardizedComponents(cwd)

        guard !cwdComponents.isEmpty,
              fileComponents.count > cwdComponents.count,
              Array(fileComponents.prefix(cwdComponents.count)) == cwdComponents else {
            return standardizedPath(filePath)
        }
        return fileComponents.dropFirst(cwdComponents.count).joined(separator: "/")
    }

    /// Single-quote a path that contains whitespace (POSIX-safe). Paths without
    /// whitespace are returned unchanged. Embedded single quotes are escaped
    /// with the standard `'\''` idiom.
    nonisolated static func shellQuoteIfNeeded(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace }) else { return path }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Path helpers

    private nonisolated static func standardizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private nonisolated static func standardizedComponents(_ path: String) -> [String] {
        standardizedPath(path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    // MARK: - Baseline tier (focus + pasteboard + ⌘V)

    /// Baseline tier: bring the session's OWN terminal to the front, VERIFY it
    /// took, then paste. We never paste into whatever happens to be frontmost —
    /// an unconfirmed front app could be Slack, a browser form, etc.
    ///
    /// `SessionFocusController.focus` is tiered (GW-162): for a plain terminal
    /// (`.unresolvable` -> `.none` strategy) it returns false WITHOUT focusing
    /// anything. So a false result is the norm here, and we fall back to the
    /// honest baseline: walk the session pid's ancestors to the owning terminal
    /// app and activate it ourselves, confirming the activation before sending
    /// ⌘V. If we can't get the terminal frontmost, we refuse.
    private func injectViaBaseline(text: String, into session: SessionState, submit: Bool) async -> Result<Void, InjectionError> {
        // Without a pid we can't find the right terminal — refuse rather than
        // paste into whatever is frontmost.
        guard let pid = session.pid else {
            Self.logger.error("Baseline inject: session has no pid to focus")
            return .failure(.noDeliverablePath)
        }

        // First try the shared focus controller (handles mux re-focus etc.);
        // for plain terminals it returns false, so fall through to our own
        // verified activation rather than trusting the frontmost app.
        let focused = await SessionFocusController.shared.focus(session: session)
        let frontmost = focused
            ? await Self.terminalIsFrontmost(forSessionPid: pid)
            : await Self.activateAndVerifyTerminal(forSessionPid: pid)

        guard frontmost else {
            Self.logger.error("Baseline inject: could not confirm the session's terminal is frontmost; refusing to paste")
            return .failure(.noDeliverablePath)
        }

        let pasted = await Self.pasteIntoFrontmost(text: text, submit: submit)
        return pasted ? .success(()) : .failure(.noDeliverablePath)
    }

    /// Resolve the bundle id of the terminal app that owns `pid` by walking the
    /// process tree to the terminal ancestor. Pure-ish seam (process tree +
    /// NSRunningApplication lookup); returns nil if no terminal ancestor or the
    /// app isn't running. Live-verify (depends on the real process tree).
    @MainActor
    private static func terminalBundleId(forSessionPid pid: Int) -> String? {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
            return nil
        }
        return app.bundleIdentifier
    }

    /// True when the frontmost app is the terminal that owns `pid`. Used to
    /// confirm a focus/activation actually landed before we paste.
    @MainActor
    private static func terminalIsFrontmost(forSessionPid pid: Int) -> Bool {
        guard let bundleId = terminalBundleId(forSessionPid: pid),
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return front == bundleId
    }

    /// Activate the session's owning terminal app, then VERIFY it became
    /// frontmost — the precondition for a safe ⌘V. Routes through the shared
    /// TerminalActivator so the GW-266 fix (`.activateAllWindows`, fully
    /// frontmost) applies to paste and to the "Go to terminal" button alike.
    @MainActor
    private static func activateAndVerifyTerminal(forSessionPid pid: Int) async -> Bool {
        await TerminalActivator.activateAndVerify(forSessionPid: pid) != nil
    }

    /// Put `text` on the pasteboard and synthesize ⌘V (and Return when
    /// `submit`) into the frontmost app. PRECONDITION: the caller has already
    /// confirmed the session's own terminal is frontmost — this never decides
    /// where to paste. Returns false if event sources can't be created (e.g.
    /// Accessibility/Input-Monitoring not granted).
    @MainActor
    private static func pasteIntoFrontmost(text: String, submit: Bool) async -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.error("Baseline paste: couldn't create CGEventSource")
            return false
        }

        // ⌘V
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        guard postKeyStroke(source: source, keyCode: vKey, command: true) else {
            return false
        }

        if submit {
            try? await Task.sleep(for: .milliseconds(30))
            let returnKey: CGKeyCode = 0x24 // kVK_Return
            _ = postKeyStroke(source: source, keyCode: returnKey, command: false)
        }
        return true
    }

    @MainActor
    private static func postKeyStroke(source: CGEventSource, keyCode: CGKeyCode, command: Bool) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            logger.error("Baseline paste: couldn't create key event")
            return false
        }
        if command {
            down.flags = .maskCommand
            up.flags = .maskCommand
        }
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
