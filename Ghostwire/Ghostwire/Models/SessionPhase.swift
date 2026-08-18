//
//  SessionPhase.swift
//  Ghostwire
//
//  Explicit state machine for Claude session lifecycle.
//  All state transitions are validated before being applied.
//

import Foundation

/// How a pending gate is answerable (GW: Codex adaptive approval flow).
///
/// Codex's approval pipeline is strictly sequential — while a PermissionRequest
/// hook holds, its terminal renders NO prompt of its own (verified from
/// codex-rs source: request_approval awaits hooks before the reviewer path).
/// So for Codex the notch chooses per session:
///  - multiplexer sessions (cmux/tmux): release the socket immediately so the
///    native prompt renders alongside the card; notch buttons answer by
///    keystroke into the addressed pane (`terminalFirst`).
///  - plain terminals: hold as usual, but hand back after a window so an
///    unanswered notch never strands the terminal (`handedOff` — card flips
///    to a focus-jump, since without a pane address injection is unsafe).
/// Claude is untouched: its own menu races the held hook natively (`held`).
enum PermissionGateMode: Sendable, Equatable {
    /// Socket held; Allow/Deny answer over the hook socket (default; all agents).
    case held
    /// Socket already released; the agent's native prompt is live. Allow/Deny
    /// inject the native menu's keystroke into the session's pane.
    case terminalFirst
    /// Hold window elapsed; socket released; native prompt is live but the
    /// session has no addressable pane — the card offers a terminal jump only.
    case handedOff
}

/// Permission context for tools waiting for approval
struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date

    /// How this gate is answerable right now. Mutates in place when the
    /// hold window elapses (held -> handedOff); the UI re-renders off it.
    var gateMode: PermissionGateMode = .held

    /// GW-413: `toolUseId` was minted by Ghostwire because the request could not
    /// be correlated to its `PreToolUse`. The gate is fully answerable — the id is
    /// only ever a dictionary key, never a routing token — but the agent's own
    /// `PostToolUse` id will never match it, so release has to fall back on tool
    /// name. Defaulted so existing call sites are unaffected.
    var correlationIsProvisional: Bool = false

    /// Format tool input for display.
    ///
    /// LOSSY ON PURPOSE — string values are clipped to 100 chars for the
    /// compact (`.inline`) one-line approval row and the dense session list.
    /// The approval surface MUST NOT use this in `.fullRaw` mode: the human
    /// has to see exactly what they're approving (GW-139 security rule).
    /// Use `rawInput` for the verbatim approval path.
    var formattedInput: String? {
        guard let input = toolInput else { return nil }
        var parts: [String] = []
        for (rawKey, value) in input {
            // Codex's exec_command uses "cmd" where Claude's Bash uses
            // "command" - normalize so approval rows read the same (GW-197)
            let key = rawKey == "cmd" ? "command" : rawKey
            let valueStr: String
            switch value.value {
            case let str as String:
                valueStr = str.count > 100 ? String(str.prefix(100)) + "..." : str
            case let num as Int:
                valueStr = String(num)
            case let num as Double:
                valueStr = String(num)
            case let bool as Bool:
                valueStr = bool ? "true" : "false"
            default:
                valueStr = "..."
            }
            parts.append("\(key): \(valueStr)")
        }
        return parts.joined(separator: "\n")
    }

    /// GW-207 alert-history command summary: a single line for the history
    /// row (truncation happens in the view via `lineLimit`). Prefers the
    /// `command`/`cmd` value (Bash / Codex exec) so the row reads as the shell
    /// line; otherwise falls back to the lossy `formattedInput`, newlines
    /// collapsed to spaces. NOT the approval surface — see `rawInput` for that.
    var commandSummary: String? {
        if let input = toolInput {
            for (rawKey, value) in input where rawKey == "command" || rawKey == "cmd" {
                if let str = value.value as? String {
                    return str.replacingOccurrences(of: "\n", with: " ")
                }
            }
        }
        return formattedInput?.replacingOccurrences(of: "\n", with: " ")
    }

    /// Verbatim tool input for the approval surface (GW-139): every key,
    /// every value, in stable key order, NEVER truncated. This is the exact
    /// string the human is approving — no clipping, no ellipsis, no markdown.
    /// `cmd` is normalized to `command` for cross-agent parity (GW-197), but
    /// values pass through untouched. Pure + nonisolated for unit testing.
    var rawInput: String? {
        guard let input = toolInput else { return nil }
        return Self.rawInput(input)
    }

    /// Pure renderer behind `rawInput` — exposed for tests. Mirrors
    /// `ToolCallView.rawInput` (the transcript path) so the approval surface
    /// and the history transcript can never disagree about what ran.
    nonisolated static func rawInput(_ input: [String: AnyCodable]) -> String {
        input
            .map { (rawKey, value) -> (String, String) in
                let key = rawKey == "cmd" ? "command" : rawKey
                let valueStr: String
                switch value.value {
                case let str as String: valueStr = str
                case let num as Int: valueStr = String(num)
                case let num as Double: valueStr = String(num)
                case let bool as Bool: valueStr = bool ? "true" : "false"
                case is NSNull: valueStr = "null"
                default: valueStr = String(describing: value.value)
                }
                return (key, valueStr)
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
    }
}

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable).
        // gateMode is included so a held -> handedOff flip publishes to SwiftUI.
        lhs.toolUseId == rhs.toolUseId &&
        lhs.toolName == rhs.toolName &&
        lhs.receivedAt == rhs.receivedAt &&
        lhs.gateMode == rhs.gateMode
    }
}

/// Explicit session phases - the state machine
enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    // MARK: - State Machine Transitions

    /// Check if a transition to the target phase is valid
    nonisolated func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        // Terminal state - no transitions out
        case (.ended, _):
            return false

        // Any state can transition to ended
        case (_, .ended):
            return true

        // Idle transitions
        case (.idle, .processing):
            return true
        case (.idle, .waitingForApproval):
            return true  // Direct permission request on idle session
        case (.idle, .waitingForInput):
            return true  // Stop seen while idle (e.g. app launched mid-turn) - GW-171
        case (.idle, .compacting):
            return true

        // Processing transitions
        case (.processing, .waitingForInput):
            return true
        case (.processing, .waitingForApproval):
            return true
        case (.processing, .compacting):
            return true
        case (.processing, .idle):
            return true  // Interrupt or quick completion

        // WaitingForInput transitions
        case (.waitingForInput, .processing):
            return true
        case (.waitingForInput, .waitingForApproval):
            return true  // Gate with no observed turn-start: a held PermissionRequest
                         // means the agent is provably blocked. Cursor GUI sessions hit
                         // this (stop -> next turn's gate, no prompt-submit between) — GW-175
        case (.waitingForInput, .idle):
            return true  // Can become idle
        case (.waitingForInput, .compacting):
            return true

        // WaitingForApproval transitions
        case (.waitingForApproval, .processing):
            return true  // Approved - tool will run
        case (.waitingForApproval, .idle):
            return true  // Denied or cancelled
        case (.waitingForApproval, .waitingForInput):
            return true  // Denied and Claude stopped
        case (.waitingForApproval, .waitingForApproval):
            return true  // Another tool needs approval (multiple pending permissions)

        // Compacting transitions
        case (.compacting, .processing):
            return true
        case (.compacting, .idle):
            return true
        case (.compacting, .waitingForInput):
            return true

        // Allow staying in same state (no-op transitions)
        default:
            return self == next
        }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: SessionPhase) -> SessionPhase? {
        canTransition(to: next) ? next : nil
    }

    /// Whether this phase indicates the session needs user attention
    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return true
        default:
            return false
        }
    }

    /// Whether this phase indicates active processing
    var isActive: Bool {
        switch self {
        case .processing, .compacting:
            return true
        default:
            return false
        }
    }

    /// Whether this is a waitingForApproval phase
    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }

    /// GW-320 race safety (Interaction Model spec §5): whether free text must NOT
    /// be injected into this session right now.
    ///
    /// The notch composer and the terminal are two live channels into one agent.
    /// If the session reached a gate while a reply was being typed, injecting the
    /// text would type into a permission menu — answering a question the user
    /// never saw. Re-check this immediately before injecting, not just when the
    /// composer was rendered.
    ///
    /// `.processing` is deliberately safe: queueing a message mid-turn is normal,
    /// supported agent behaviour, not a race.
    nonisolated var blocksTextInjection: Bool {
        switch self {
        case .waitingForApproval, .ended:
            return true
        case .idle, .processing, .waitingForInput, .compacting:
            return false
        }
    }
}

// MARK: - Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.processing, .processing): return true
        case (.waitingForInput, .waitingForInput): return true
        case (.waitingForApproval(let ctx1), .waitingForApproval(let ctx2)):
            return ctx1 == ctx2
        case (.compacting, .compacting): return true
        case (.ended, .ended): return true
        default: return false
        }
    }
}

// MARK: - Debug Description

extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            return "idle"
        case .processing:
            return "processing"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForApproval(let ctx):
            return "waitingForApproval(\(ctx.toolName))"
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
