//
//  AskUserQuestionPayload.swift
//  Ghostwire
//
//  GW-321 (State B — Choice). Typed model for Claude Code's `AskUserQuestion`
//  tool_input, which arrives on the held `PermissionRequest` the notch is
//  already keeping open for approvals.
//
//  Schema verified against live Claude Code 2.1.220 + 96 historical calls in the
//  GW-318 spike (docs/interaction-model-payloads.md):
//
//    { "questions": [ { "question": "...", "header": "...", "multiSelect": false,
//                       "options": [ { "label": "...", "description": "...",
//                                      "preview": "..." } ] } ] }
//
//  Notes that drove the shape:
//   - 1-4 questions per call; multi-question is common (33/96), not an edge case.
//   - 2-4 options each. `preview` is optional and newer (70/424 options).
//   - Codex's `request_user_input` is near-identical and adds a per-question `id`,
//     so `id` is decoded when present — it is a better correlation key than the
//     question text, which is all Claude gives us.
//
//  `Codable` from day one per spec §8: these states serialize over the gateway
//  API so a future phone client renders them natively rather than scraping a TUI.
//

import Foundation

/// One selectable option on a question.
struct AskUserQuestionOption: Codable, Equatable, Sendable, Identifiable {
    let label: String
    let description: String?
    /// Monospace preview body (mockups, code, diffs). Optional and newer.
    let preview: String?

    var id: String { label }
}

/// A single question with its options.
struct AskUserQuestion: Codable, Equatable, Sendable, Identifiable {
    /// Codex (`request_user_input`) supplies a stable id; Claude does not.
    let questionId: String?
    let question: String
    /// Short chip label (~12 chars in practice).
    let header: String?
    let options: [AskUserQuestionOption]
    let multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case questionId = "id"
        case question, header, options, multiSelect
    }

    /// Stable identity, for `ForEach` and for keying answers.
    ///
    /// MUST NOT be the raw `questionId`: that is nil for every Claude payload,
    /// so a multi-question call gave every question the same nil identity and
    /// SwiftUI rendered one question twice with selections in lockstep (found
    /// in live testing, not by the tests — they never rendered anything).
    var id: String { questionId ?? question }

    /// Correlation key — same value as `id`. Claude keys its own `answers`
    /// dictionary by the question text, which is the fallback here.
    var key: String { id }
}

/// The full `tool_input` payload.
struct AskUserQuestionRequest: Codable, Equatable, Sendable {
    let questions: [AskUserQuestion]
}

// MARK: - Parsing from the hook payload

extension AskUserQuestionRequest {

    /// Build from the `AnyCodable` bag the hook socket delivers.
    ///
    /// Returns nil rather than a partial render: a Choice surface that silently
    /// drops a question would let the user answer something they never saw. The
    /// caller falls back to the "answer in terminal" bar, which is honest.
    nonisolated init?(toolInput: [String: AnyCodable]) {
        guard let rawQuestions = toolInput["questions"]?.value as? [Any] else { return nil }

        let parsed = rawQuestions.compactMap { Self.parseQuestion($0) }
        guard !parsed.isEmpty, parsed.count == rawQuestions.count else { return nil }

        self.questions = parsed
    }

    nonisolated private static func parseQuestion(_ raw: Any) -> AskUserQuestion? {
        guard let dict = raw as? [String: Any],
              let question = dict["question"] as? String,
              let rawOptions = dict["options"] as? [Any] else { return nil }

        let options = rawOptions.compactMap { option -> AskUserQuestionOption? in
            guard let o = option as? [String: Any],
                  let label = o["label"] as? String else { return nil }
            return AskUserQuestionOption(
                label: label,
                description: o["description"] as? String,
                preview: o["preview"] as? String
            )
        }
        guard !options.isEmpty, options.count == rawOptions.count else { return nil }

        return AskUserQuestion(
            questionId: dict["id"] as? String,
            question: question,
            header: dict["header"] as? String,
            options: options,
            // Absent means single-select; every sampled Claude payload sends it.
            multiSelect: dict["multiSelect"] as? Bool ?? false
        )
    }
}

// MARK: - Reply formatting

extension AskUserQuestionRequest {

    /// The message sent back over the held socket as the deny reason, which the
    /// hook emits as `decision.message` and the model reads as the tool result.
    ///
    /// Deliberately mirrors Claude Code's own wording for an answered question so
    /// the model sees the phrasing it already understands. Verified end-to-end in
    /// the GW-318 spike: the model consumed it and continued with the answer.
    ///
    /// `answers` is keyed by `AskUserQuestion.key`. Values are free text, not
    /// option labels — the terminal always offers a "Type something" row, so real
    /// answers frequently match no option, and the notch must not be narrower.
    nonisolated func replyMessage(answers: [String: String]) -> String {
        let pairs = questions.compactMap { question -> String? in
            guard let answer = answers[question.key], !answer.isEmpty else { return nil }
            return "\"\(question.question)\"=\"\(answer)\""
        }
        guard !pairs.isEmpty else {
            return "The user dismissed the question without answering."
        }
        return "Your questions have been answered: "
            + pairs.joined(separator: ", ")
            + ". You can now continue with these answers in mind."
    }
}
