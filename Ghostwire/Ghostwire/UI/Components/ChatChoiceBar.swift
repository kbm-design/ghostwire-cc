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
    /// Answers keyed by `AskUserQuestion.key`, already free-text. The completion
    /// reports whether the verdict reached the held socket, so the bar can show
    /// sent/failed instead of assuming delivery (GW-163 glyph pattern).
    let onAnswer: ([String: String], @escaping (Bool) -> Void) -> Void
    let onGoToTerminal: () -> Void

    /// Which question is on screen. One at a time, like the terminal: showing
    /// all of them at once burned the notch's height and pushed Send out of
    /// reach, and a 4-option question couldn't be read without scrolling.
    @State private var index = 0

    private enum Delivery { case idle, sending, sent, failed }
    @State private var delivery: Delivery = .idle

    /// Selected option labels per question key (a set, for multi-select).
    @State private var selections: [String: Set<String>] = [:]
    /// Free-text answers per question key, when the user picks "Something else".
    @State private var freeText: [String: String] = [:]
    /// Which questions are in free-text mode.
    @State private var freeTextActive: Set<String> = []

    /// Locked once the reply is in flight or delivered — the socket reply is
    /// one-shot per gate. Re-enabled only on confirmed failure (spec §5).
    private var isLocked: Bool {
        delivery == .sending || delivery == .sent
    }

    private var current: AskUserQuestion {
        request.questions[min(index, request.questions.count - 1)]
    }

    private var isLastQuestion: Bool {
        index >= request.questions.count - 1
    }

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
            if request.questions.count > 1 {
                stepper
            }

            // Take the height the question needs and scroll ONLY when it genuinely
            // can't fit — a fixed cap left the question in a scroller while an
            // empty transcript above it kept the space. The footer is outside
            // either branch, so Send is always reachable: reaching past the notch
            // edge crosses the dwell threshold and dismisses it (GW-264), and an
            // unreachable Send was a dead end with no way to answer or escape.
            ViewThatFits(in: .vertical) {
                questionBlock(current)
                ScrollView(.vertical) {
                    questionBlock(current)
                }
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: index)
    }

    // MARK: - Stepper

    /// Mirrors the terminal's per-question tabs: where you are, what's left, and
    /// what's already answered. Tappable so a wrong answer is one click to fix.
    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(Array(request.questions.enumerated()), id: \.element.id) { position, question in
                let isCurrent = position == index
                let isAnswered = !answer(for: question).isEmpty

                Button {
                    withAnimation { index = position }
                } label: {
                    HStack(spacing: 4) {
                        if isAnswered {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text(question.header ?? "Q\(position + 1)")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isCurrent ? agentTint.opacity(0.22) : Color.white.opacity(0.06),
                        in: Capsule()
                    )
                    .foregroundStyle(isCurrent ? agentTint : .white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
            }

            Spacer()

            Text("\(index + 1) of \(request.questions.count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    // MARK: - One question

    @ViewBuilder
    private func questionBlock(_ question: AskUserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // With several questions the stepper already carries the header,
                // so repeating it here would just spend height twice.
                if let header = question.header, request.questions.count == 1 {
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
        .disabled(isLocked)
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

        // Single-select answers advance, matching the terminal: one question,
        // one choice, next. Multi-select can't — there's no way to know you're
        // done picking — so it waits for Next.
        if !question.multiSelect, !isLastQuestion {
            withAnimation { index += 1 }
        }
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
            .disabled(isLocked)

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
                    .disabled(isLocked)
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
            .disabled(isLocked)
            .help("Answer in the terminal instead")

            if delivery != .idle {
                deliveryStatus
            }

            Spacer()

            if index > 0 && !isLocked {
                Button {
                    withAnimation { index -= 1 }
                } label: {
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }

            if isLastQuestion {
                primaryButton(title: sendTitle, enabled: isComplete && !isLocked) { send() }
                    .help(request.questions.count > 1
                          ? "Answer every question to send"
                          : "Send answer")
            } else {
                // Multi-select has no natural end, so it needs an explicit Next.
                primaryButton(title: "Next", enabled: !answer(for: current).isEmpty) {
                    withAnimation { index += 1 }
                }
                .help("Answer this question to continue")
            }
        }
    }

    private var sendTitle: String {
        switch delivery {
        case .idle:    return "Send"
        case .sending: return "Sending..."
        case .sent:    return "Sent"
        case .failed:  return "Retry"
        }
    }

    /// GW-163 sent/failed pattern: the chip disabling on tap only proves the tap
    /// registered. Delivery is reported from the socket write, so a verdict that
    /// never reached the agent doesn't read as success.
    @ViewBuilder
    private var deliveryStatus: some View {
        switch delivery {
        case .sent:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("Delivered")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.green.opacity(0.85))
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Didn't reach \(agentName)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.yellow.opacity(0.9))
        case .sending, .idle:
            EmptyView()
        }
    }

    private func primaryButton(title: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(enabled ? .black : .white.opacity(0.4))
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(
                    enabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func send() {
        guard isComplete, !isLocked else { return }
        delivery = .sending
        var answers: [String: String] = [:]
        for question in request.questions {
            answers[question.key] = answer(for: question)
        }
        onAnswer(answers) { wasDelivered in
            // Re-enable only on confirmed failure (spec §5), so a lost verdict
            // can be retried without letting a delivered one be sent twice.
            delivery = wasDelivered ? .sent : .failed
        }
    }
}
