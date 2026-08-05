//
//  ChatPlanReviewBar.swift
//  Ghostwire
//
//  GW-322 (State C — Plan review). Renders a pending `ExitPlanMode` as the plan
//  itself plus Accept / Revise, replacing the generic approval bar that showed
//  the plan as one unrendered `plan: # Plan…` blob under an Allow/Deny pair.
//
//  Shares State B's shape deliberately (`ChatChoiceBar`, GW-321): same delivery
//  state machine, same one-shot lock, same Terminal escape hatch, same GW-163
//  sent/failed glyph. Both states ride the same held `PermissionRequest` socket,
//  so they should not feel like two different products.
//
//  Rendering rules from the spec (§4) and the GW-322 capture:
//   - The plan renders in full and literally. Notch scrolls it under a cap;
//     the detached window gets a much taller one. Neither truncates.
//   - `allowedPrompts` is rendered whenever present. Accepting a plan that
//     carries them is also a batch permission grant, so hiding them would let
//     the user authorize commands they were never shown.
//   - Revise reuses State D's composer, pre-focused, and sends the feedback as
//     the deny message — which IS the delivery. No injection, no pane needed.
//   - One-shot: the socket reply is single-use per gate, and a replayed message
//     is model-visible (GW-318).
//

import SwiftUI

struct ChatPlanReviewBar: View {
    let request: ExitPlanModeRequest
    let agentName: String
    let agentTint: Color
    /// Approve the `ExitPlanMode` tool. Reports whether the verdict reached the
    /// held socket so the bar can show sent/failed rather than assuming delivery.
    let onAccept: (@escaping (Bool) -> Void) -> Void
    /// Deny with the typed feedback as the message.
    let onRevise: (String, @escaping (Bool) -> Void) -> Void
    let onGoToTerminal: () -> Void

    @Environment(\.ghostwireSurface) private var surface

    private enum Delivery { case idle, sending, accepted, revised, failed }
    @State private var delivery: Delivery = .idle
    @State private var isRevising = false
    @State private var feedback = ""
    @FocusState private var isFeedbackFocused: Bool

    /// Locked once a verdict is in flight or delivered — one reply per gate.
    /// Re-enabled only on confirmed failure (spec §5).
    private var isLocked: Bool {
        delivery == .sending || delivery == .accepted || delivery == .revised
    }

    /// How much height the plan may claim before it scrolls. The notch has ~190
    /// to spend before it grows; the detached window has room to show a whole
    /// plan at once, which is the §3 "notch: capped / detached: full" split.
    /// Neither value elides anything — past the cap the plan scrolls.
    private var planMaxHeight: CGFloat {
        surface == .window ? 460 : 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    PlanMarkdownView(markdown: request.plan)

                    if !request.allowedPrompts.isEmpty {
                        allowedPromptsBlock
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: planMaxHeight)

            if isRevising {
                feedbackField
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isRevising)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("PLAN")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(agentTint.opacity(0.18), in: Capsule())
                .foregroundStyle(agentTint)

            Text("\(agentName) is ready to start")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))

            Spacer()

            // The plan is also on disk and survives the turn, so name the file
            // rather than the full path — the notch is too narrow for a path and
            // the useful part is knowing it persists.
            if let path = request.planFilePath {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
        }
    }

    // MARK: - Pre-authorized commands

    /// Accepting is also a batch permission grant when the payload carries
    /// `allowedPrompts`. Rendered as its own labelled block, not folded into the
    /// plan body, so it cannot be skimmed past as prose.
    private var allowedPromptsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9))
                Text("Accepting also pre-approves")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(TerminalColors.amber)

            ForEach(request.allowedPrompts) { grant in
                HStack(alignment: .top, spacing: 6) {
                    Text(grant.tool)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .foregroundColor(.white.opacity(0.6))
                    // Verbatim: this is the grant being made (GW-139 rule).
                    Text(verbatim: grant.prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TerminalColors.amber.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(TerminalColors.amber.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Revise composer

    /// State D's input box, pre-focused (spec §3 State C). Focus here is an
    /// explicit user action — the user tapped Revise — so it does not violate
    /// §4.5's "never steal keyboard focus", which governs passive reveals.
    private var feedbackField: some View {
        TextField("What should \(agentName) change?", text: $feedback, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .focused($isFeedbackFocused)
            .disabled(isLocked)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(agentTint.opacity(0.55), lineWidth: 1)
                    )
            )
            .onSubmit { sendRevision() }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
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
            .help("Review this plan in the terminal instead")

            if delivery != .idle {
                deliveryStatus
            }

            Spacer()

            if isRevising {
                Button {
                    isRevising = false
                    isFeedbackFocused = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .disabled(isLocked)

                primaryButton(title: reviseTitle,
                              enabled: !trimmedFeedback.isEmpty && !isLocked) {
                    sendRevision()
                }
                .help("Send this feedback and ask for a revised plan")
            } else {
                Button {
                    isRevising = true
                    isFeedbackFocused = true
                } label: {
                    Text("Revise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
                .help("Tell \(agentName) what to change")

                // FOCUS SAFETY (GW-139): the same explicit ⌘⇧↩ as State A's
                // Allow — never `.defaultAction`, so a stray Return while the
                // feedback field has focus can't accept a plan.
                primaryButton(title: acceptTitle, enabled: !isLocked) { accept() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Accept this plan (⌘⇧↩)")
            }
        }
    }

    private var trimmedFeedback: String {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var acceptTitle: String {
        switch delivery {
        case .idle:     return "Accept"
        case .sending:  return "Sending..."
        case .accepted: return "Accepted"
        case .revised:  return "Sent"
        case .failed:   return "Retry"
        }
    }

    private var reviseTitle: String {
        switch delivery {
        case .sending: return "Sending..."
        case .revised: return "Sent"
        case .failed:  return "Retry"
        default:       return "Send"
        }
    }

    /// GW-163 sent/failed pattern: a button disabling on tap only proves the tap
    /// registered. Delivery is reported from the socket write, so a verdict that
    /// never reached the agent doesn't read as success.
    @ViewBuilder
    private var deliveryStatus: some View {
        switch delivery {
        case .accepted, .revised:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text(delivery == .accepted ? "Accepted" : "Revision sent")
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

    // MARK: - Actions

    private func accept() {
        guard !isLocked else { return }
        delivery = .sending
        onAccept { wasDelivered in
            delivery = wasDelivered ? .accepted : .failed
        }
    }

    private func sendRevision() {
        guard !isLocked, !trimmedFeedback.isEmpty else { return }
        delivery = .sending
        isFeedbackFocused = false
        onRevise(trimmedFeedback) { wasDelivered in
            delivery = wasDelivered ? .revised : .failed
        }
    }
}
