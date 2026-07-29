//
//  ChatChoiceBar.swift
//  Ghostwire
//
//  GW-321 (State B — Choice). Renders a pending `AskUserQuestion` as the actual
//  question plus tappable options, replacing the "answer in the terminal" dead
//  end that threw the payload away while holding it in memory.
//
//  The answer goes back over the socket the notch is *already* holding for this
//  gate — no keystroke injection. GW-318 proved a deny-with-message reads to the
//  model as the answer ("Your answer was Spaces.").
//
//  Rendering rules from the spec (§4) and the spike:
//   - Question text renders verbatim and in full. Never truncate or paraphrase.
//   - Every question in the call gets answered before sending; multi-question
//     calls are common (33/96 sampled), not an edge case.
//   - A free-text row ships alongside the chips: the terminal always offers
//     "Type something", and real answers frequently match no option label.
//   - One-shot: chips disable on send. A replayed answer is model-visible — in
//     the spike, a repeated message got called out as "replaying stale feedback".
//

import SwiftUI

struct ChatChoiceBar: View {
    let request: AskUserQuestionRequest
    let agentName: String
    let agentTint: Color
    /// Answers keyed by `AskUserQuestion.key`, already free-text.
    let onAnswer: ([String: String]) -> Void
    let onGoToTerminal: () -> Void

    /// Selected option labels per question key (a set, for multi-select).
    @State private var selections: [String: Set<String>] = [:]
    /// Free-text answers per question key, when the user picks "Something else".
    @State private var freeText: [String: String] = [:]
    /// Which questions are in free-text mode.
    @State private var freeTextActive: Set<String> = []
    /// One-shot latch — the socket reply can only be sent once.
    @State private var hasSent = false

    private var isComplete: Bool {
        request.questions.allSatisfy { !answer(for: $0).isEmpty }
    }

    /// Resolved answer for a question: free text if the user chose that, else the
    /// selected labels joined (multi-select answers arrive as one string).
    private func answer(for question: AskUserQuestion) -> String {
        if freeTextActive.contains(question.key) {
            return freeText[question.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let picked = selections[question.key] ?? []
        return question.options
            .filter { picked.contains($0.label) }
            .map(\.label)
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.questions) { question in
                questionBlock(question)
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - One question

    @ViewBuilder
    private func questionBlock(_ question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let header = question.header {
                    Text(header)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(agentTint.opacity(0.18), in: Capsule())
                        .foregroundStyle(agentTint)
                }
                if question.multiSelect {
                    Text("choose any")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer()
            }

            // Verbatim, never truncated (spec §4.1).
            Text(question.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            ForEach(question.options) { option in
                optionRow(question: question, option: option)
            }

            freeTextRow(question)
        }
    }

    // MARK: - Option row

    @ViewBuilder
    private func optionRow(question: AskUserQuestion, option: AskUserQuestionOption) -> some View {
        let picked = (selections[question.key] ?? []).contains(option.label)
            && !freeTextActive.contains(question.key)

        Button {
            select(question: question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: glyph(multiSelect: question.multiSelect, picked: picked))
                    .font(.system(size: 12))
                    .foregroundColor(picked ? agentTint : .white.opacity(0.3))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }

                    // Newer field (70/424 sampled options) - monospace body.
                    if let preview = option.preview {
                        Text(preview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.04))
                            )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(picked ? agentTint.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                picked ? agentTint.opacity(0.5) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(hasSent)
    }

    private func glyph(multiSelect: Bool, picked: Bool) -> String {
        if multiSelect {
            return picked ? "checkmark.square.fill" : "square"
        }
        return picked ? "largecircle.fill.circle" : "circle"
    }

    private func select(question: AskUserQuestion, label: String) {
        freeTextActive.remove(question.key)
        var picked = selections[question.key] ?? []
        if question.multiSelect {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
        }
        selections[question.key] = picked
    }

    // MARK: - Free text ("Type something" parity)

    @ViewBuilder
    private func freeTextRow(_ question: AskUserQuestion) -> some View {
        let active = freeTextActive.contains(question.key)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                if active {
                    freeTextActive.remove(question.key)
                } else {
                    freeTextActive.insert(question.key)
                    selections[question.key] = []
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                        .foregroundColor(active ? agentTint : .white.opacity(0.3))
                    Text("Something else...")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(hasSent)

            if active {
                TextField("Your answer...", text: binding(for: question.key), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(agentTint.opacity(0.4), lineWidth: 1)
                            )
                    )
                    .disabled(hasSent)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { freeText[key] ?? "" },
            set: { freeText[key] = $0 }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // Escape hatch, never an auto-pick (spec §3 State B).
            Button {
                onGoToTerminal()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Answer in the terminal instead")

            Spacer()

            Button {
                send()
            } label: {
                Text(hasSent ? "Sent" : "Send")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isComplete && !hasSent ? .black : .white.opacity(0.4))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        isComplete && !hasSent
                            ? Color.white.opacity(0.95)
                            : Color.white.opacity(0.1),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isComplete || hasSent)
            .help(request.questions.count > 1 ? "Answer every question to send" : "Send answer")
        }
    }

    private func send() {
        guard isComplete, !hasSent else { return }
        hasSent = true  // one-shot: never replay an answer to the same gate
        var answers: [String: String] = [:]
        for question in request.questions {
            answers[question.key] = answer(for: question)
        }
        onAnswer(answers)
    }
}
