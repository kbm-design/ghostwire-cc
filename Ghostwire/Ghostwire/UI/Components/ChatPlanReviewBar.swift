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
//   - `allowedPrompts` is rendered whenever present, and (GW-362) pinned
//     OUTSIDE the capped plan scroller. Accepting a plan that carries them is
//     also a batch permission grant, so hiding them would let the user
//     authorize commands they were never shown. Only the plan was ever meant
//     to be height-capped; a grant that scrolled out of view while Accept
//     stayed live was exactly the failure the block exists to prevent.
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
    @State private var planContentHeight: CGFloat = 0
    @FocusState private var isFeedbackFocused: Bool

    /// Locked once a verdict is in flight, delivered, **or confirmed failed** —
    /// one reply per gate, and after a failure there is no gate left to reply on.
    ///
    /// GW-362: spec §5 says "re-enable only on confirmed failure", and that is
    /// not implementable against this socket. `sendPermissionResponse` removes
    /// the pending entry *before* the write and closes the fd on the failure
    /// branch too, so a second press hits `guard let pending = removeValue(…)`
    /// and fails again, permanently. Re-enabling would ship a Retry that cannot
    /// work — a second false affordance in the surface whose whole job is not
    /// having one. The live action after a failure is Terminal.
    private var isLocked: Bool {
        delivery != .idle
    }

    /// The escape hatch outlives the verdict: it is the only thing left that can
    /// still resolve the gate once the socket is gone.
    private var isTerminalActionEnabled: Bool {
        delivery != .sending
    }

    /// How much height the plan may claim before it scrolls. The notch has ~190
    /// to spend before it grows; the detached window has room to show a whole
    /// plan at once, which is the §3 "notch: capped / detached: full" split.
    /// Neither value elides anything — past the cap the plan scrolls.
    private var planMaxHeight: CGFloat {
        surface == .window ? 460 : 200
    }

    /// How much height the grant *list* may claim before it scrolls inside its
    /// own block. The block's label — which carries the count — is never inside
    /// that scroller, so "this plan also grants N commands" is always on screen
    /// even when the list itself is long. Bounded because the notch chat panel
    /// is a fixed 500pt: an unbounded pinned list would push Accept off the
    /// bottom, which is the same defect wearing a different hat.
    private var grantsListMaxHeight: CGFloat {
        surface == .window ? 180 : 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // GW-362: pinned above the plan, never inside it. The plan may
            // scroll; the batch grant the user is about to make may not.
            if !request.allowedPrompts.isEmpty {
                AllowedPromptsBlock(grants: request.allowedPrompts,
                                    listMaxHeight: grantsListMaxHeight)
            }

            planScroller

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

    // MARK: - Plan

    /// The plan body only. Named so a test can assert on its type and prove the
    /// grant block is not inside it (GW-362) — the regression this file exists
    /// to prevent is structural, so the test has to be structural too.
    var planScrollerContent: some View {
        PlanMarkdownView(markdown: request.plan)
            .padding(.trailing, 4)
            // Report the content height so the fade only appears when there
            // is genuinely more plan below (test drive: a plan clipped
            // mid-sentence at the cap reads as truncated, and "truncated"
            // is the one thing this surface must never look like).
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PlanContentHeightKey.self,
                                           value: proxy.size.height)
                }
            )
    }

    private var planScroller: some View {
        ScrollView(.vertical) {
            planScrollerContent
        }
        .frame(maxHeight: planMaxHeight)
        .onPreferenceChange(PlanContentHeightKey.self) { planContentHeight = $0 }
        .overlay(alignment: .bottom) {
            if planContentHeight > planMaxHeight {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .allowsHitTesting(false)
            }
        }
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
                // GW-362: on a failed delivery this is the only live control
                // left, so it stops looking like the quiet tertiary option.
                .foregroundColor(delivery == .failed ? .black : .white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(delivery == .failed
                            ? Color.white.opacity(0.95)
                            : Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isTerminalActionEnabled)
            .help(delivery == .failed
                  ? "The verdict didn't reach \(agentName) — answer this plan in the terminal"
                  : "Review this plan in the terminal instead")

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
        // Not "Retry" (GW-362): the socket for this gate is gone, so a retry
        // here can only fail. The button stays disabled and says what it did.
        case .failed:   return "Didn't send"
        }
    }

    private var reviseTitle: String {
        switch delivery {
        case .sending: return "Sending..."
        case .revised: return "Sent"
        case .failed:  return "Didn't send"
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
                // GW-362: say where the decision went, not just that it failed.
                // The gate is still open — in the terminal, not here.
                Text("Didn't reach \(agentName) — answer in the terminal")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.yellow.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Pre-authorized commands

/// Accepting is also a batch permission grant when the payload carries
/// `allowedPrompts`. Rendered as its own labelled block, not folded into the
/// plan body, so it cannot be skimmed past as prose.
///
/// GW-362: its own type, and pinned by `ChatPlanReviewBar` outside the plan
/// scroller. It used to be the last child *inside* that capped scroller, so any
/// plan longer than the cap scrolled the grant list out of view while Accept
/// stayed visible and enabled — the user accepting a batch grant they were
/// never shown, which is the exact thing `docs/interaction-model-payloads.md`
/// calls a required render element.
///
/// The list can still scroll inside the block when it is long, but the label
/// carrying the count never does: "there are N grants here" is always on
/// screen, so a scrolled list reads as more-below rather than as nothing.
struct AllowedPromptsBlock: View {
    let grants: [ExitPlanModeAllowedPrompt]
    /// Cap for the list only — see `ChatPlanReviewBar.grantsListMaxHeight`.
    let listMaxHeight: CGFloat

    @State private var listContentHeight: CGFloat = 0

    private var overflows: Bool { listContentHeight > listMaxHeight }

    /// GW-362 (Codex review, finding 3): the measured height starts at 0, so
    /// framing the scroller to `min(measured, cap)` gives the grants a 0pt
    /// viewport on the first layout pass — the count label would be the only
    /// visible thing while Accept is already live, which is a smaller version
    /// of the bug this block exists to prevent. Worse, a zero-height ScrollView
    /// may not emit its child's geometry preference at all, so it could never
    /// recover. Start from an estimate instead: wrong by a few points for one
    /// frame is fine, zero is not.
    private static let estimatedRowHeight: CGFloat = 20
    private static let rowSpacing: CGFloat = 6

    private var estimatedListHeight: CGFloat {
        guard !grants.isEmpty else { return 0 }
        let rows = CGFloat(grants.count)
        return min(rows * Self.estimatedRowHeight + (rows - 1) * Self.rowSpacing, listMaxHeight)
    }

    /// Never zero for a non-empty grant list.
    var listHeight: CGFloat {
        listContentHeight > 0 ? min(listContentHeight, listMaxHeight) : estimatedListHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label

            ScrollView(.vertical) {
                rows
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: GrantsContentHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
            }
            // Height, not maxHeight: a ScrollView is greedy and would claim the
            // whole cap for a single grant. Measure, then take the smaller —
            // falling back to an estimate so this is never 0 (see listHeight).
            .frame(height: listHeight)
            .onPreferenceChange(GrantsContentHeightKey.self) { listContentHeight = $0 }
            .overlay(alignment: .bottom) {
                if overflows {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                        .allowsHitTesting(false)
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

    /// Never inside the scroller — the count is the part that must survive a
    /// long list, so the user can tell there is more than they can see.
    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "key.fill")
                .font(.system(size: 9))
            Text(grants.count == 1
                 ? "Accepting also pre-approves 1 command"
                 : "Accepting also pre-approves \(grants.count) commands")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(TerminalColors.amber)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(grants) { grant in
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
    }
}

/// Content height of the plan scroller, so the bar can tell "the plan fits"
/// from "there is more below" and only draw the fade in the second case.
private struct PlanContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Same, for the grant list inside `AllowedPromptsBlock`.
private struct GrantsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
