//
//  ExitPlanModePayload.swift
//  Ghostwire
//
//  GW-322 (State C — Plan review). Typed model for Claude Code's `ExitPlanMode`
//  tool_input, which arrives on the held `PermissionRequest` the notch is already
//  keeping open for approvals — the same gate State B rides (GW-321).
//
//  Schema re-verified against live Claude Code 2.1.222 (8 driven PTY runs,
//  GW-322) on top of the GW-318 spike (docs/interaction-model-payloads.md):
//
//    { "plan": "# Plan…",                       // markdown, always present
//      "planFilePath": "~/.claude/plans/….md",  // the plan is also on disk
//      "allowedPrompts": [ { "tool": "Bash", "prompt": "…" } ] }  // optional
//
//  Notes that drove the shape:
//   - `PreToolUse` and `PermissionRequest` both fire, ~1s apart, carrying an
//     IDENTICAL `tool_input`. We gate on `PermissionRequest` (see the type doc
//     on `ExitPlanModeRequest` for why the ticket's `PreToolUse` is wrong).
//   - `allowedPrompts` is optional — absent in all 5 ExitPlanMode calls captured
//     on 2.1.222, present in 5/6 historical ones. When present it is a batch
//     permission grant riding along with acceptance, so it MUST be rendered.
//
//  `Codable` from day one per spec §8: these states serialize over the gateway
//  API so a future phone client renders them natively rather than scraping a TUI.
//

import Foundation

/// One command the model wants pre-authorized as part of accepting the plan.
///
/// Accepting a plan that carries these is *also* a batch permission grant. The
/// review surface renders every one of them; a plan whose grants were hidden is
/// a plan the human did not actually review.
struct ExitPlanModeAllowedPrompt: Codable, Equatable, Sendable, Identifiable {
    let tool: String
    let prompt: String

    var id: String { "\(tool)\u{001F}\(prompt)" }
}

/// The full `ExitPlanMode` `tool_input` payload.
///
/// **Gate point.** GW-322 captured the live sequence for an `ExitPlanMode` round
/// trip and it matches GW-318's finding, not the ticket's:
///
///     09:27:48  PreToolUse         ExitPlanMode  permission_mode=plan  (tool_use_id)
///     09:27:48  PermissionRequest  ExitPlanMode  permission_mode=plan  (no tool_use_id)
///     09:27:54  Notification       permission_prompt
///
/// Both events carry the same `tool_input`, so either could *render*. But holding
/// `PreToolUse` suspends the whole permission flow — the terminal menu never
/// appears — which makes the notch a single point of failure for the user's own
/// agent. Holding `PermissionRequest` leaves the terminal fully usable (its plan
/// menu rendered ~6s into a 35s hold, measured), so that is the gate, with spec
/// §5 invalidation carrying the resulting race. This reuses State A's shipped
/// socket verbatim.
struct ExitPlanModeRequest: Codable, Equatable, Sendable {
    /// The plan, as markdown. Rendered in full and never truncated (spec §4.1).
    let plan: String
    /// Where Claude also wrote the plan. Survives the turn, so the detached
    /// window can reopen a plan after the gate resolves.
    let planFilePath: String?
    /// Commands pre-authorized by accepting. Empty when the payload omits them.
    let allowedPrompts: [ExitPlanModeAllowedPrompt]
}

// MARK: - Parsing from the hook payload

extension ExitPlanModeRequest {

    /// Build from the `AnyCodable` bag the hook socket delivers.
    ///
    /// Lenient about `planFilePath` (a missing path hides nothing — the plan
    /// text is the content) and strict about `allowedPrompts`: if the key is
    /// present but any entry fails to parse, this returns nil so the caller
    /// falls back to the verbatim approval bar. Rendering 1 of 2 pre-authorized
    /// commands would let the user grant a command they were never shown, which
    /// is the one failure this surface must not have.
    nonisolated init?(toolInput: [String: AnyCodable]) {
        guard let plan = toolInput["plan"]?.value as? String,
              !plan.isEmpty else { return nil }

        var prompts: [ExitPlanModeAllowedPrompt] = []
        if let raw = toolInput["allowedPrompts"]?.value {
            guard let rawList = raw as? [Any] else { return nil }
            prompts = rawList.compactMap { entry -> ExitPlanModeAllowedPrompt? in
                guard let dict = entry as? [String: Any],
                      let tool = dict["tool"] as? String,
                      let prompt = dict["prompt"] as? String else { return nil }
                return ExitPlanModeAllowedPrompt(tool: tool, prompt: prompt)
            }
            guard prompts.count == rawList.count else { return nil }
        }

        self.plan = plan
        self.planFilePath = toolInput["planFilePath"]?.value as? String
        self.allowedPrompts = prompts
    }
}

// MARK: - Reply formatting

extension ExitPlanModeRequest {

    /// The message sent back over the held socket as the deny reason, which the
    /// hook emits as `decision.message` and the model reads as revision feedback.
    ///
    /// Verified end-to-end in GW-322: denying an `ExitPlanMode` with this shape
    /// kept `permission_mode: plan`, and the model edited the plan and
    /// re-presented it via a second `ExitPlanMode` carrying the requested change.
    /// No keystroke injection and no addressable pane are involved — the deny
    /// message *is* the delivery, so the ticket's "inject the feedback as the
    /// next message" is a step this path does not need.
    ///
    /// One-shot per gate: replaying a stale revision is model-visible (GW-318
    /// caught the model calling it out as "replaying stale feedback").
    nonisolated func reviseMessage(feedback: String) -> String {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "The user did not accept this plan. Ask what they want changed "
                + "before presenting it again."
        }
        return "The user reviewed this plan in Ghostwire and asked for changes: "
            + trimmed
            + " Revise the plan and present it again."
    }
}
