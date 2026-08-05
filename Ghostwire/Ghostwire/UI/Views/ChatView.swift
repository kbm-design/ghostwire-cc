//
//  ChatView.swift
//  Ghostwire
//
//  Redesigned chat interface with clean visual hierarchy
//

import AppKit
import Combine
import Defaults
import SwiftUI
import os

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: AgentPanelViewModel

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    /// GW-162: why the last send failed (sends used to drop silently)
    @State private var sendFailureHint: String?
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: AgentPanelViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                Group {
                    if isLoading {
                        loadingState
                    } else if history.isEmpty {
                        emptyState
                    } else {
                        messageList
                    }
                }
                // GW-321: while a question is pending, IT is the content. The
                // scrollback was holding ~40% of the panel to show almost
                // nothing while the options below it got clipped, so cap it and
                // let the Choice bar take the rest. Context still travels with
                // the affordance (spec §4.2) — just a turn of it, not a screen.
                .frame(maxHeight: hasPendingChoice ? Self.contextStripHeight : .infinity)

                // Approval bar, interactive prompt, or Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" {
                        // GW-321 State B: render the actual question + options when
                        // the payload parses. The "answer in terminal" bar is now
                        // only the fallback for a payload we can't render faithfully.
                        if let choice = session.pendingChoice {
                            ChatChoiceBar(
                                request: choice,
                                agentName: agentName,
                                agentTint: agentTint,
                                onAnswer: { answers, completion in
                                    answerChoice(choice, answers: answers, completion: completion)
                                },
                                onGoToTerminal: { focusTerminal() }
                            )
                            // Claim height ahead of the transcript: while a question
                            // is pending it IS the content, and the scrollback above
                            // was keeping space the options needed (GW-321 test drive).
                            .layoutPriority(1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                        } else {
                            interactivePromptBar
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity
                                ))
                        }
                    } else if tool == "ExitPlanMode", let plan = session.pendingPlanReview {
                        // GW-322 State C: the plan rendered, with Accept/Revise.
                        // Falls through to the verbatim approval bar when the
                        // payload doesn't parse — that bar still shows the plan
                        // and every allowedPrompt, just unrendered.
                        ChatPlanReviewBar(
                            request: plan,
                            agentName: agentName,
                            agentTint: agentTint,
                            onAccept: { completion in acceptPlan(completion: completion) },
                            onRevise: { feedback, completion in
                                revisePlan(plan, feedback: feedback, completion: completion)
                            },
                            onGoToTerminal: { focusTerminal() }
                        )
                        .layoutPriority(1)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                    } else {
                        approvalBar(tool: tool)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                } else {
                    inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.contentType.id)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else {
                // No history for this session yet — ignore, don't exit
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when multiplexer messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            // GW-320: restore an unsent reply from a previous visit — the view is
            // torn down on every notch dismiss, the draft must not be.
            inputText = viewModel.draft(for: sessionId)

            // Auto-focus input when chat opens and multiplexer messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: inputText) { _, text in
            viewModel.setDraft(text, for: sessionId)
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                    .lineLimit(1)

                // GW-311: with several agents running you cannot tell whose
                // approval you are about to allow or deny from the title alone —
                // and keyboard approval (GW-267) is gated to the focused chat.
                // Same badge treatment as the agents list, so the drill-in reads
                // as the same session you clicked.
                if let agentLabel = session.agentLabel {
                    Text(agentLabel)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(agentTint.opacity(0.18), in: Capsule())
                        .foregroundStyle(agentTint)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help("Back to agents")
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            // GW-311: an IDE session mirrors from the agent's own transcript, so
            // the wait is on the agent, not on the user doing something here.
            if isIDEAgent {
                Text("Messages appear as \(agentName) works")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 12)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: sessionId)
                            .padding(.horizontal, 12)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .ghostwireScrollGeometryChange(
                pauseAutoscroll: pauseAutoscroll,
                resumeAutoscroll: resumeAutoscroll,
                isAutoscrollPaused: isAutoscrollPaused
            )
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    /// GW-162: input enables only when the session's pane is actually
    /// addressable (cmux refs or tmux tty) - not off process-tree flags,
    /// which phantom-enabled input and then dropped sends silently
    private var targetResolution: MultiplexerTargetResolution {
        MultiplexerTargetResolver.resolve(session: session)
    }

    private var canSendMessages: Bool {
        targetResolution.isResolvable
    }

    /// Whether a Choice or a plan review is on screen, so the transcript above
    /// can yield its height to it instead of padding it out with empty space.
    /// GW-322 folds State C in: a plan needs at least as much room as a question.
    private var hasPendingChoice: Bool {
        session.pendingChoice != nil || session.pendingPlanReview != nil
    }

    /// How much scrollback stays visible above a pending question — enough for
    /// the preceding turn, not enough to crowd out the options.
    private static let contextStripHeight: CGFloat = 76

    /// GW-320 (State D): the agent has finished its turn and is explicitly
    /// waiting on the human. Distinct from "the box happens to be enabled" —
    /// this is the moment the notch exists to catch, so it reads differently.
    ///
    /// Reads `livePhase`, not the `session` snapshot: the snapshot only refreshes
    /// when `instances` publishes a record that differs, so a session adopted
    /// mid-flight can sit on a stale `.idle` and never light up.
    private var isAwaitingReply: Bool {
        livePhase == .waitingForInput
    }

    /// Live phase from the store rather than the `session` snapshot, which is
    /// only refreshed when `instances` publishes. The race check has to read
    /// what is true *now*, not what was true when the view last updated.
    private var livePhase: SessionPhase {
        sessionMonitor.instances.first { $0.sessionId == sessionId }?.phase ?? session.phase
    }

    /// User-facing reason a send must not go out, or nil when injection is safe.
    /// The decision itself lives on `SessionPhase.blocksTextInjection` (GW-320,
    /// spec §5) so it is unit-testable; this only names it for the human.
    private func injectionBlocker(_ phase: SessionPhase) -> String? {
        guard phase.blocksTextInjection else { return nil }
        switch phase {
        case .waitingForApproval(let ctx):
            return "\(agentName) is waiting on approval for \(ctx.toolName) — answer that first"
        case .ended:
            return "This session has ended"
        default:
            return "\(agentName) can't take a message right now"
        }
    }

    /// GW-311: agents that also run inside an IDE have no terminal pane to
    /// address when launched that way, so telling the user to "open it in
    /// tmux/cmux" is a dead end — the session is already running, just not
    /// somewhere we can type into.
    private var isIDEAgent: Bool {
        guard let agent = session.agent?.lowercased() else { return false }
        return GenericHookInstaller.all.contains { $0.agentId == agent }
    }

    /// Placeholder names the gap when input is disabled. For an unaddressable
    /// IDE session it says what this surface *does* do rather than prescribing
    /// something the user cannot act on.
    private var inputPlaceholder: String {
        switch targetResolution {
        case .cmux, .tmuxTty:
            // GW-320 State D: name the moment when the agent is actually waiting.
            return isAwaitingReply ? "Reply to \(agentName)..." : "Message \(agentName)..."
        case .unresolvable(.cmuxRefsMissing):
            return isIDEAgent
                ? "Following along — reply in \(agentName)"
                : "Waiting for \(agentName)'s pane identity (hooks)..."
        case .unresolvable(.ttyMissing):
            return isIDEAgent
                ? "Following along — reply in \(agentName)"
                : "No tty recorded for this session"
        case .unresolvable(.notInMultiplexer):
            return isIDEAgent
                ? "Following along — reply in \(agentName)"
                : "Open \(agentName) in tmux/cmux to enable messaging"
        }
    }

    /// Display name for this session's agent ("Claude" / "Codex"); neutral fallback if untagged
    private var agentName: String {
        session.agentLabel ?? "Agent"
    }

    /// Per-agent tint — single source via AgentIdentity (GW-138).
    private var agentTint: Color {
        AgentIdentity.tint(for: session.agent)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            // GW-162: failed sends surface here instead of vanishing into
            // debug logs (cmux socket policy, vanished panes, ...)
            if let hint = sendFailureHint {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(hint)
                        .font(.caption2)
                        .lineLimit(2)
                    Spacer()
                }
                .foregroundColor(.yellow.opacity(0.9))
            }

            inputRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    private var inputRow: some View {
        // Bottom-aligned so the send button stays level with the last line as the
        // field grows, rather than drifting to the middle of a tall box.
        HStack(alignment: .bottom, spacing: 10) {
            // GW-163 note: a paperclip/NSOpenPanel attach was tried and removed -
            // the notch's window level sits above every system panel, so the
            // picker rendered underneath it (test-drive finding). File attach
            // flows are Finder-copy -> clipboard -> send, or drag -> Shelf ->
            // Send to Agent; both land @path without fighting the windowing.
            // GW-320: grows downward as you type instead of scrolling the text
            // sideways out of view. A reply you can't read back is a reply you
            // can't check before sending. Capped so the composer can never crowd
            // out the transcript above it; past the cap it scrolls internally.
            TextField(inputPlaceholder, text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                // GW-320 State D: agent-tinted border marks the field
                                // as the live reply target. Passive (spec §4.5) — it
                                // never steals focus or expands the notch.
                                .strokeBorder(
                                    isAwaitingReply && canSendMessages
                                        ? agentTint.opacity(0.55)
                                        : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                )
                .animation(.easeOut(duration: 0.2), value: isAwaitingReply)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessages || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
            .help("Send message")
        }
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            // GW-139: the verbatim string the human is approving. Full-raw
            // mode renders this untruncated; the lossy `toolInput` is only
            // the compact inline fallback.
            toolRawInput: session.pendingToolRawInput,
            onApprove: { approvePermission() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            isInTmux: session.isInMultiplexer,
            agentName: agentName,
            onGoToTerminal: { focusTerminal() }
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        // GW-162: tiered focus (cmux CLI / tmux + app activation); yabai
        // is an enhancement, not a gate
        Task {
            await SessionFocusController.shared.focus(session: session)
        }
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    /// GW-321 State B: deliver a Choice answer over the socket already held open
    /// for this gate — no keystroke injection, so no pane is required and there is
    /// no race with the terminal for the delivery itself.
    ///
    /// The transport is the deny channel because that is the only payload a hook
    /// can express: there is no hook field that supplies a real tool result
    /// (verified in GW-318 against the hooks reference). The hook turns `reason`
    /// into `decision.message`, and the model reads it as the answer.
    private func answerChoice(_ request: AskUserQuestionRequest, answers: [String: String],
                              completion: @escaping (Bool) -> Void) {
        sessionMonitor.denyPermission(
            sessionId: sessionId,
            reason: request.replyMessage(answers: answers),
            delivered: { wasDelivered in
                Task { @MainActor in completion(wasDelivered) }
            }
        )
    }

    /// GW-322 State C — Accept. Approves the `ExitPlanMode` tool over the same
    /// held socket State A uses; `ghostwire-hook.py` supplies the `updatedInput`
    /// the allow decision needs (see the note there — without it Claude Code
    /// silently discards an `ExitPlanMode` allow and leaves its own plan menu up).
    ///
    /// Accepting this way lands the session in `permission_mode: default`, i.e.
    /// the terminal menu's "Yes, manually approve edits" — never its "auto mode"
    /// row. Measured in GW-322; worth keeping, because the notch must not be a
    /// quieter way to hand an agent broader permissions than the terminal would.
    private func acceptPlan(completion: @escaping (Bool) -> Void) {
        sessionMonitor.approvePermission(
            sessionId: sessionId,
            delivered: { wasDelivered in
                Task { @MainActor in completion(wasDelivered) }
            }
        )
    }

    /// GW-322 State C — Revise. The feedback goes back as the deny message on the
    /// held socket, which is the whole delivery: verified in GW-322 that this
    /// keeps `permission_mode: plan` and the model revises and re-presents via a
    /// second `ExitPlanMode`. No keystroke injection, so no pane is required and
    /// this works for sessions State D can't reach.
    private func revisePlan(_ request: ExitPlanModeRequest, feedback: String,
                            completion: @escaping (Bool) -> Void) {
        sessionMonitor.denyPermission(
            sessionId: sessionId,
            reason: request.reviseMessage(feedback: feedback),
            delivered: { wasDelivered in
                Task { @MainActor in completion(wasDelivered) }
            }
        )
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Check before clearing, so a send that can't go out doesn't cost the
        // user their draft. The authoritative check is in `sendToSession`.
        if let blocker = injectionBlocker(livePhase) {
            sendFailureHint = blocker
            return
        }

        inputText = ""

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task {
            await sendToSession(text)
        }
    }

    private func sendToSession(_ text: String) async {
        let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "ChatSend")
        let resolution = targetResolution
        logger.debug("sendToSession: resolution=\(String(describing: resolution), privacy: .public) pid=\(session.pid ?? 0)")

        guard let target = await findTarget(for: resolution) else {
            logger.debug("sendToSession: no target found")
            sendFailureHint = noTargetHint(for: resolution)
            return
        }

        logger.debug("sendToSession: found target \(target.targetString, privacy: .public)")

        // GW-320 (spec §5): re-verify immediately before injecting. The tmux
        // target lookup above is async, and that gap is exactly where the agent
        // can hit a gate — never inject into a screen that changed underneath us.
        if let blocker = injectionBlocker(livePhase) {
            logger.debug("sendToSession: aborted, phase is now \(String(describing: self.livePhase), privacy: .public)")
            sendFailureHint = blocker
            // Hand the draft back rather than swallowing it, unless the user has
            // already started typing something else.
            if inputText.isEmpty {
                inputText = text
            }
            return
        }

        let result = await TmuxController.shared.sendMessage(text, to: target)
        logger.debug("sendToSession: sendMessage result=\(result)")

        if result {
            sendFailureHint = nil
        } else {
            // GW-162: a failed send must say why - on cmux the usual cause
            // is the socket policy (cmuxOnly default / pending restart)
            sendFailureHint = await Self.failureHint(for: target)
        }
    }

    /// Resolution -> concrete target (tmux needs a live pane-tty lookup)
    private func findTarget(for resolution: MultiplexerTargetResolution) async -> TmuxTarget? {
        switch resolution {
        case .cmux(let workspace, let surface):
            return .cmux(workspace: workspace, surface: surface)
        case .tmuxTty(let tty):
            return await TmuxTargetFinder.shared.findTarget(forTty: tty)
        case .unresolvable:
            return nil
        }
    }

    private func noTargetHint(for resolution: MultiplexerTargetResolution) -> String {
        switch resolution {
        case .tmuxTty:
            return "No tmux pane matches this session's tty"
        case .cmux, .unresolvable:
            return "Couldn't locate this session's pane"
        }
    }

    /// Why did a resolved send fail? For cmux, probe the socket policy.
    private static func failureHint(for target: TmuxTarget) async -> String {
        switch target.multiplexer {
        case .tmux:
            return "tmux send failed — the pane may have closed"
        case .cmux:
            switch await CmuxAccessProbe.probe() {
            case .closedByPolicy(_, needsRestart: true):
                return "Restart cmux to apply its automation socket mode"
            case .closedByPolicy(_, needsRestart: false):
                return "cmux blocks external apps — set Settings → Automation → Socket Control Mode to Automation, then restart cmux"
            case .notRunning:
                return "cmux isn't running"
            case .unavailable:
                return "cmux CLI not found"
            case .ok:
                return "Send failed — the pane may have closed"
            }
        }
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    // GW-144 message display size. Full raw = the prompt verbatim:
    // monospaced, unrendered, and never truncated (GW-139 security rule —
    // the human must see exactly what the agent was told).
    @Default(.messageDisplayMode) private var displayMode

    var body: some View {
        HStack {
            Spacer(minLength: displayMode == .fullRaw ? 24 : 60)

            Group {
                if displayMode == .fullRaw {
                    Text(verbatim: text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    GhostwireMarkdownText(text, color: .white, fontSize: 13)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.white.opacity(0.15))
            )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // White dot indicator
            Circle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            GhostwireMarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "") {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    // GW-144/GW-139 full-raw: transcript tool rows show the exact command
    // verbatim and never truncate — the history must match what ran.
    @Default(.messageDisplayMode) private var displayMode

    private var fullRaw: Bool { displayMode == .fullRaw }

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.white
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT Task tools, NOT Edit tools)
    private var canExpand: Bool {
        tool.name != "Task" && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if fullRaw && !tool.input.isEmpty {
                    // Full-raw mode: EVERY input shape verbatim, no formatter
                    // in the path — MCPToolFormatter.formatArgs truncates
                    // values (30 chars) and caps args (3), which is lossy
                    // long before lineLimit matters (GW-139 rule).
                    Text(verbatim: Self.rawInput(tool.input))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if tool.name == "Task" && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(fullRaw ? nil : 1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(fullRaw ? nil : 1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(fullRaw ? nil : 1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(fullRaw ? nil : 1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && tool.name != "Task" && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }

    /// Full-raw rendering of a tool's input: every key, every value,
    /// untruncated, in stable order. Internal for tests (GW-139 rule:
    /// the transcript must show exactly what the tool was given).
    static func rawInput(_ input: [String: String]) -> String {
        input
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5
    @Default(.messageDisplayMode) private var displayMode

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools); full-raw mode
            // keeps even subagent summaries untruncated (GW-139 rule)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(displayMode == .fullRaw ? nil : 1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .italic()
                .lineLimit(isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let isInTmux: Bool
    let agentName: String
    let onGoToTerminal: () -> Void

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text("\(agentName) needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Answer in the terminal")
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    /// Lossy, single-line summary — used only for the compact `.inline` mode.
    let toolInput: String?
    /// Verbatim, untruncated command (GW-139). Rendered in `.fullRaw` mode.
    let toolRawInput: String?
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    // GW-144/GW-139: in full-raw mode the command under approval is shown
    // verbatim and untruncated — what you approve is what runs.
    @Default(.messageDisplayMode) private var displayMode

    /// Cap the verbatim block's height so a huge payload can't push the
    /// buttons off-screen — but it stays fully scrollable + selectable, so
    /// nothing is hidden from the human (GW-139: no truncation, ever).
    private let rawMaxHeight: CGFloat = 160

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if displayMode == .fullRaw {
                    // Verbatim path: the exact string being approved. Never
                    // the lossy `toolInput` — that clips at 100 chars and would
                    // hide injected tails (GW-139 injection-attack visibility).
                    if let raw = toolRawInput, !raw.isEmpty {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(verbatim: raw)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: rawMaxHeight)
                    }
                } else if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Deny this request")
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            // Allow button.
            // FOCUS SAFETY (GW-139): deliberate activation only — explicit
            // ⌘⇧↩ shortcut, NOT `.defaultAction`/`.keyboardShortcut(.return)`,
            // so a stray Enter/Space while typing can never approve. `.plain`
            // style also keeps it from inheriting default-button key behavior.
            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.95))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("Allow (⌘⇧↩)")
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Scroll Geometry Availability Wrapper

private extension View {
    @ViewBuilder
    func ghostwireScrollGeometryChange(
        pauseAutoscroll: @escaping () -> Void,
        resumeAutoscroll: @escaping () -> Void,
        isAutoscrollPaused: Bool
    ) -> some View {
        if #available(macOS 15.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    resumeAutoscroll()
                }
            }
        } else {
            self
        }
    }
}
