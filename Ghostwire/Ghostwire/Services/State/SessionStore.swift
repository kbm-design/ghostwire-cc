//
//  SessionStore.swift
//  Ghostwire
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import os

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// GW-362: deferred cleanup for gates whose verdict never reached the agent,
    /// keyed by toolUseId. Without these, a socket failure could hold
    /// `waitingForApproval` — and the persistent glow — forever.
    private var undeliveredGateSweeps: [String: Task<Void, Never>] = [:]

    /// Sessions archived or ended this app run (GW-194). Their transcripts
    /// keep a fresh mtime, so without a tombstone the next discovery rescan
    /// would resurrect them as provisional rows. Cleared by a real hook event.
    private var dismissedSessionIds: Set<String> = []

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionBlocked(let hookEvent, let reason):
            await processPermissionBlocked(hookEvent, reason: reason)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionsDiscovered(let snapshot):
            await processSessionsDiscovered(snapshot)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        // A real hook event always registers, even for a session that was
        // archived earlier this run (e.g. claude --resume)
        dismissedSessionIds.remove(sessionId)

        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)
        let wasProvisional = session.isProvisional
        if isNewSession {
            // GW-341: identity at birth, so a wrong tag can be traced to the
            // event that caused it instead of guessed at from the UI.
            Self.logger.info(
                "New session \(sessionId.prefix(8), privacy: .public) agent=\(event.source ?? "<none>", privacy: .public) via \(event.event, privacy: .public)"
            )
        }
        if wasProvisional {
            session = Self.upgradedFromProvisional(session, event: event)
        }

        // GW-341: the hook's `source` is stamped by the installer that wrote the
        // hook (GHOSTWIRE_AGENT=cursor|codex|…), so it is authoritative for
        // identity — more so than discovery, which infers the agent from which
        // directory a transcript sits in. Agent used to be set once at creation,
        // so a session adopted through any other path kept that path's guess for
        // its whole life. Re-stamp on every event that carries a source.
        if let source = event.source, !source.isEmpty, session.agent != source {
            if let previous = session.agent {
                Self.logger.info(
                    "Session \(sessionId.prefix(8), privacy: .public) agent corrected: \(previous, privacy: .public) -> \(source, privacy: .public)"
                )
            }
            session.agent = source
        }

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
            session.isInCmux = ProcessTreeBuilder.shared.isInCmux(pid: pid, tree: tree)
        }
        if let ws = event.cmuxWorkspace, let surf = event.cmuxSurface {
            session.cmuxWorkspaceRef = ws
            session.cmuxSurfaceRef = surf
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        if let path = event.transcriptPath, !path.isEmpty {
            session.transcriptPath = path
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            releaseCursorParserState(sessionId: sessionId, agent: session.agent)
            dismissedSessionIds.insert(sessionId)
            return
        }

        let newPhase = event.determinePhase()

        if !mayExitWaitingForApproval(current: session.phase, newPhase: newPhase, event: event) {
            // GW-192: a pending approval must never vanish while the agent is still
            // blocked on it. Concurrent subagent events (PreToolUse/PostToolUse with
            // the same session_id) would otherwise recompute the phase to .processing
            // and drop the approval row from the notch.
            Self.logger.debug("Holding waitingForApproval against \(event.event, privacy: .public) (unrelated to pending tool)")
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        // GW-311: Cursor's chat is built from the hook stream (its transcript is
        // written lazily/incompletely). This runs before the gate status update
        // below so the tool row already exists when a PermissionRequest lands.
        applyCursorHookChat(event: event, session: &session)

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            let context = PermissionContext(
                toolUseId: toolUseId,
                toolName: event.tool ?? "unknown",
                toolInput: event.toolInput,
                receivedAt: Date(),
                correlationIsProvisional: event.toolUseIdIsProvisional
            )
            setPendingPermission(context, in: &session)
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.event == "PostToolUse", let toolUseId = event.toolUseId {
            removePendingPermission(toolUseId: toolUseId, from: &session)
            // GW-413: the queue has to drop provisional gates the same way the
            // phase does, or `isUnansweredGate` keeps answering true for a ghost
            // entry the real id can never remove. Exactly-one-or-abstain, matching
            // the server's release rule — never guess between two same-tool gates.
            let provisional = session.pendingPermissions.filter {
                $0.correlationIsProvisional && $0.toolName == event.tool
            }
            if provisional.count == 1, let match = provisional.first {
                removePendingPermission(toolUseId: match.toolUseId, from: &session)
            }
        }

        if event.event == "Stop" {
            session.subagentState = SubagentState()
            session.pendingPermissions.removeAll()
        }

        sessions[sessionId] = session
        publishState()

        if isNewSession || wasProvisional {
            // GW-193: events that never sync the file (Notification, …) left
            // new sessions titled by folder name — parse once at adoption.
            // A provisional's first hook also re-adopts: its discovery-time
            // parse may have read a lossy-decoded (wrong) cwd and come up
            // empty — the fill-only guard makes the retry clobber-safe.
            await adoptConversationInfo(sessionId: sessionId, agent: session.agent, cwd: session.cwd)
        }

        if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    /// GW-192: while a permission is pending, only events that actually resolve it
    /// may move the phase. Everything else (concurrent subagent tool events, idle
    /// notifications, phase recomputes) must hold the approval in place — the hook
    /// socket is still held open and the agent is still blocked waiting.
    ///
    /// Legitimate exits:
    /// - another PermissionRequest (queueing/replacement, existing behavior)
    /// - PostToolUse for the pending tool itself (user approved in the terminal)
    /// - Stop (turn ended, e.g. denied in the terminal — monitor cancels the socket)
    /// - session ended
    /// User verdicts from the notch, JSONL tool completion, socket failures and
    /// interrupts flow through their own SessionEvent cases, not this path.
    private func mayExitWaitingForApproval(current: SessionPhase, newPhase: SessionPhase, event: HookEvent) -> Bool {
        guard case .waitingForApproval(let ctx) = current else { return true }
        if newPhase.isWaitingForApproval { return true }
        if case .ended = newPhase { return true }
        if event.event == "PostToolUse", event.toolUseId == ctx.toolUseId { return true }
        // GW-413: a provisional gate's id was minted here, so the agent's real
        // PostToolUse id can never equal it. Fall back on the tool name, else the
        // approval bar sticks until Stop over a tool that already ran.
        if event.event == "PostToolUse", ctx.correlationIsProvisional, event.tool == ctx.toolName { return true }
        if event.event == "Stop" { return true }
        return false
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            // nil → SessionState derives it, including the empty-cwd guard
            projectName: nil,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            agent: event.source,
            transcriptPath: event.transcriptPath,
            phase: .idle
        )
    }

    /// GW-194: the first real hook event confirms a provisional session in
    /// place — same sessionId key, so no duplicate rows. The discovery cwd
    /// can be a lossy dirname decode; the hook event's cwd is authoritative.
    private static func upgradedFromProvisional(_ session: SessionState, event: HookEvent) -> SessionState {
        var upgraded = session
        upgraded.isProvisional = false
        if session.cwd != event.cwd {
            upgraded = SessionState(
                sessionId: session.sessionId,
                cwd: event.cwd,
                agent: session.agent,
                transcriptPath: session.transcriptPath,
                phase: session.phase,
                pendingPermissions: session.pendingPermissions,
                chatItems: session.chatItems,
                toolTracker: session.toolTracker,
                subagentState: session.subagentState,
                conversationInfo: session.conversationInfo,
                lastActivity: session.lastActivity,
                createdAt: session.createdAt
            )
        }
        return upgraded
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if event.tool == "Task", let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            }

        case "PostToolUse":
            if event.tool == "Task" {
                Self.logger.debug("PostToolUse for Task received (subagent still running)")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func setPendingPermission(_ context: PermissionContext, in session: inout SessionState) {
        removePendingPermission(toolUseId: context.toolUseId, from: &session)
        session.pendingPermissions.append(context)
    }

    private func removePendingPermission(toolUseId: String, from session: inout SessionState) {
        session.pendingPermissions.removeAll { $0.toolUseId == toolUseId }
    }

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }
        guard isUnansweredGate(session, toolUseId: toolUseId) else {
            // GW-362: a late allow for a gate the terminal already resolved.
            Self.logger.debug("Dropping stale approval for \(toolUseId.prefix(12), privacy: .public) - gate already answered")
            return
        }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)
        removePendingPermission(toolUseId: toolUseId, from: &session)

        // Check if there are other tools still waiting for approval
        if let nextPending = session.pendingPermissions.first {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(nextPending)
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.toolUseId.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        removePendingPermission(toolUseId: toolUseId, from: &session)
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = session.pendingPermissions.first {
                let newPhase = SessionPhase.waitingForApproval(nextPending)
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.toolUseId.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Whether `toolUseId` is still an unanswered gate in this session.
    ///
    /// GW-362 (Codex adversarial review, finding 1). Verdict outcomes are now
    /// emitted from the socket-write completion, which runs on the socket queue
    /// and is therefore **unordered** against the hook stream. If the user
    /// answers in the terminal first, `PostToolUse` clears the gate and marks
    /// the tool succeeded — and a delivery completion arriving after that would
    /// otherwise walk a finished tool back to `.running` (allow) or `.error`
    /// (socket failure), showing a resolved plan as failed.
    ///
    /// True when it is the live permission context, or when it still sits in
    /// the explicit pending queue. The queue is authoritative here: walking
    /// `chatItems` can resurrect old `.waitingForApproval` rows as ghost prompts
    /// after their socket has already been resolved or cancelled.
    private func isUnansweredGate(_ session: SessionState, toolUseId: String) -> Bool {
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            return true
        }
        return session.pendingPermissions.contains { $0.toolUseId == toolUseId }
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }
        guard isUnansweredGate(session, toolUseId: toolUseId) else {
            // GW-362: see processPermissionApproved.
            Self.logger.debug("Dropping stale denial for \(toolUseId.prefix(12), privacy: .public) - gate already answered")
            return
        }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)
        removePendingPermission(toolUseId: toolUseId, from: &session)

        // Check if there are other tools still waiting for approval
        if let nextPending = session.pendingPermissions.first {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(nextPending)
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.toolUseId.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// A verdict that could not be written to the held hook socket.
    ///
    /// GW-362 decided what this means for the UI, and it is deliberately *not*
    /// a resolution. The agent never got the verdict, so the gate is still open
    /// — it just cannot be answered from the notch any more: `sendPermissionResponse`
    /// drops the pending entry and closes the fd even on the failure branch, so
    /// there is no socket left to retry against. The decision has moved to the
    /// terminal.
    ///
    /// So the phase is **held** at `waitingForApproval`, which keeps the State
    /// B/C bar on screen to say "didn't reach the agent — answer in the
    /// terminal" instead of vanishing as if the verdict had landed. It clears
    /// itself the moment the agent moves on: `mayExitWaitingForApproval` already
    /// releases on a matching `PostToolUse`, on `Stop`, and on `ended`, which is
    /// spec §5's "resolved in-terminal → the notch affordance self-invalidates".
    ///
    /// This used to drop the phase to `.idle`, but nothing ever reached it — its
    /// only trigger was `respondToPermissionBySession`, which had no callers.
    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }
        guard isUnansweredGate(session, toolUseId: toolUseId) else {
            // GW-362 (review finding 1): the terminal already resolved this
            // gate. Marking it .error now would show a finished plan as failed.
            Self.logger.debug("Dropping stale socket failure for \(toolUseId.prefix(12), privacy: .public) - gate already answered")
            return
        }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)
        removePendingPermission(toolUseId: toolUseId, from: &session)

        // A tool whose verdict never landed does not release the gate, so there
        // is no "move to the next pending tool" here — the failed one is still
        // the pending one. Hold the phase exactly as it is.
        sessions[sessionId] = session

        // GW-362 (review finding 2): holding the gate depends on a later hook
        // event to release it, and the socket-failure case is exactly when that
        // event may never come — the hook already exited, and the user may kill
        // the agent, close the terminal, or simply never answer. Bound it.
        if let pid = session.pid, !Self.processIsAlive(pid) {
            Self.logger.info("Undelivered gate for a dead agent (pid \(pid)) - releasing immediately")
            releaseUndeliveredGate(sessionId: sessionId, toolUseId: toolUseId)
            return
        }
        scheduleUndeliveredGateSweep(sessionId: sessionId, toolUseId: toolUseId)
    }

    // MARK: - Blocked gates (GW-408)

    /// A gate the socket server refused before it could be shown: undecodable,
    /// or impossible to correlate to a tool call. PR #77 started denying these,
    /// which is the right posture — but it wrote the deny and told nobody, so
    /// the tool just failed in the terminal with no trace anywhere in the app.
    ///
    /// This is deliberately *not* `processSocketFailure`. That one holds the
    /// phase at `waitingForApproval` because the gate is still answerable in the
    /// terminal. Here it is not: the deny has already gone back over the socket
    /// and the agent has moved on. Showing an actionable bar would be a lie.
    /// What the user needs is a record of what was blocked and why, and to know
    /// that re-running is how they get asked properly.
    private func processPermissionBlocked(_ event: HookEvent, reason: String) async {
        let sessionId = event.sessionId
        dismissedSessionIds.remove(sessionId)

        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)
        if session.isProvisional {
            session = Self.upgradedFromProvisional(session, event: event)
        }
        if let source = event.source, !source.isEmpty, session.agent != source {
            session.agent = source
        }
        if event.pid != nil { session.pid = event.pid }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        // A synthetic id: the whole reason we are here is that no tool_use_id
        // could be established, so this row must not collide with a real one.
        let toolName = event.tool ?? "unknown"
        let rowId = "gw-blocked-\(UUID().uuidString.prefix(8))"
        var input: [String: String] = ["ghostwire": reason]
        if let hookInput = event.toolInput {
            for (key, value) in hookInput {
                if let str = value.value as? String { input[key] = str }
            }
        }
        session.chatItems.append(ChatHistoryItem(
            id: rowId,
            type: .toolCall(ToolCallItem(
                name: toolName,
                input: input,
                status: .error,
                result: reason,
                structuredResult: nil,
                subagentTools: []
            )),
            timestamp: Date()
        ))

        sessions[sessionId] = session
        publishState()

        Self.logger.error(
            "Gate handed back to the terminal for \(sessionId.prefix(8), privacy: .public) tool=\(toolName, privacy: .public): \(reason, privacy: .public)"
        )

        let agent = session.agent
        let folder = URL(fileURLWithPath: session.cwd).lastPathComponent
        let command = input["command"] ?? input["file_path"]
        await MainActor.run {
            AlertHistoryStore.shared.record(
                agent: agent,
                sessionId: sessionId,
                kind: "permission",
                detail: toolName,
                folder: folder,
                command: command,
                toolUseId: rowId
            )
            AlertHistoryStore.shared.markPermissionOutcome(
                sessionId: sessionId, toolUseId: rowId, outcome: "blocked"
            )
        }

        if isNewSession {
            await adoptConversationInfo(sessionId: sessionId, agent: session.agent, cwd: session.cwd)
        }
    }

    // MARK: - Undelivered gate cleanup (GW-362)

    /// Is the agent process still there to answer in its terminal? A gate whose
    /// agent is gone can never be resolved, so it must not keep glowing.
    private nonisolated static func processIsAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        // ESRCH means gone; EPERM means alive but not ours to signal.
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Backstop for an undelivered gate whose agent is still alive: the user may
    /// yet answer in the terminal, so give them a window rather than yanking the
    /// bar away — but don't hold it forever if they never do.
    ///
    /// Ten minutes, deliberately generous. What a held gate actually costs while
    /// it waits is one row in the Agents tab and a *static* 0.32 edge-glow floor
    /// (`ContentView.effectiveGlowOpacity`) — the pulse animation fires only when
    /// a permission first arrives, so nothing re-nudges the user. A cheap standing
    /// cue is worth more than a short deadline that clears a gate out from under
    /// someone who stepped away mid-task. The dead-agent check below handles the
    /// case that actually needs prompt cleanup.
    private var undeliveredGateTTLSeconds: Double = 600

    /// Test seam — 180s is unusable in a unit test.
    func setUndeliveredGateTTLForTesting(_ seconds: Double) {
        undeliveredGateTTLSeconds = seconds
    }

    private func scheduleUndeliveredGateSweep(sessionId: String, toolUseId: String) {
        undeliveredGateSweeps[toolUseId]?.cancel()
        let ttl = undeliveredGateTTLSeconds
        undeliveredGateSweeps[toolUseId] = Task {
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.sweepUndeliveredGate(sessionId: sessionId, toolUseId: toolUseId)
        }
    }

    private func sweepUndeliveredGate(sessionId: String, toolUseId: String) {
        undeliveredGateSweeps.removeValue(forKey: toolUseId)
        guard let session = sessions[sessionId],
              isUnansweredGate(session, toolUseId: toolUseId) else {
            // Released normally by a hook event — nothing to do. This is the
            // expected path when the user answers in the terminal.
            return
        }
        Self.logger.info("Undelivered gate \(toolUseId.prefix(12), privacy: .public) unanswered after \(self.undeliveredGateTTLSeconds)s - releasing")
        releaseUndeliveredGate(sessionId: sessionId, toolUseId: toolUseId)
        publishState()
    }

    /// Drop a gate that can no longer be answered. The tool keeps its `.error`
    /// status (the verdict genuinely never landed); only the phase is released,
    /// so the session stops demanding attention it can't act on.
    private func releaseUndeliveredGate(sessionId: String, toolUseId: String) {
        guard var session = sessions[sessionId] else { return }
        guard case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId else {
            return
        }
        if let nextPending = session.pendingPermissions.first {
            // Another gate is still genuinely open — hand off rather than idle.
            let newPhase = SessionPhase.waitingForApproval(nextPending)
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
            }
        } else {
            session.phase = .idle
        }
        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        // GW-191: Codex sessions read rollout transcripts, Claude reads ~/.claude/projects
        let conversationInfo: ConversationInfo
        if session.agent == "codex" {
            conversationInfo = await CodexTranscriptParser.shared.parse(sessionId: payload.sessionId)
        } else {
            conversationInfo = await ConversationParser.shared.parse(
                sessionId: payload.sessionId,
                cwd: session.cwd
            )
        }
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    // MARK: - Cursor Hook-Sourced Chat (GW-311)

    /// Builds Cursor chat items from the hook event stream. Cursor's transcript
    /// is written lazily and often incompletely, so unlike Claude/Codex (which
    /// mirror a JSONL file) each Cursor turn is reconstructed from the hooks:
    /// the prompt, each tool call + its output, and the assistant's reply all
    /// arrive as discrete events. No-op for every other agent.
    ///
    /// Runs before the gate's status update in `processHookEvent`, so a tool row
    /// already exists when its PermissionRequest lands. Ids are stable
    /// (tool_use_id for tools, a per-session sequence for prose), keeping the
    /// append idempotent if an event is delivered twice.
    private func applyCursorHookChat(event: HookEvent, session: inout SessionState) {
        guard session.agent == "cursor" else { return }

        switch event.event {
        case "UserPromptSubmit":
            appendCursorProse(role: .user, text: event.message, session: &session)

        case "AgentMessage":
            appendCursorProse(role: .assistant, text: event.message, session: &session)

        case "PermissionRequest":
            guard let toolId = event.toolUseId, let name = event.tool else { return }
            upsertCursorTool(in: &session, id: toolId, name: name,
                             input: event.toolInput, status: .waitingForApproval, result: nil)

        case "PostToolUse":
            guard let toolId = event.toolUseId else { return }
            // tool_output rides in on `message` (forwarded by the hook script).
            upsertCursorTool(in: &session, id: toolId, name: event.tool ?? "Tool",
                             input: event.toolInput, status: .success, result: event.message)

        default:
            break
        }
    }

    private enum CursorProseRole { case user, assistant }

    private func appendCursorProse(role: CursorProseRole, text: String?, session: inout SessionState) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        session.cursorHookSeq += 1
        let id = "cursor-msg-\(session.sessionId)-\(session.cursorHookSeq)"
        let type: ChatHistoryItemType = role == .user ? .user(text) : .assistant(text)
        session.chatItems.append(ChatHistoryItem(id: id, type: type, timestamp: Date()))
    }

    /// Creates a tool row keyed by tool_use_id, or advances an existing one.
    /// Never regresses a settled tool back to pending, and only fills a result
    /// once — so a duplicate PostToolUse can't clobber the first output.
    private func upsertCursorTool(in session: inout SessionState, id: String, name: String,
                                  input rawInput: [String: AnyCodable]?, status: ToolStatus, result: String?) {
        if let idx = session.chatItems.firstIndex(where: { $0.id == id }),
           case .toolCall(var tool) = session.chatItems[idx].type {
            if tool.status == .success || tool.status == .error || tool.status == .interrupted { return }
            tool.status = status
            if let result, !result.isEmpty, tool.result == nil { tool.result = result }
            session.chatItems[idx] = ChatHistoryItem(
                id: id, type: .toolCall(tool), timestamp: session.chatItems[idx].timestamp
            )
        } else {
            let tool = ToolCallItem(
                name: name, input: Self.stringInput(rawInput), status: status,
                result: result, structuredResult: nil, subagentTools: []
            )
            session.chatItems.append(ChatHistoryItem(id: id, type: .toolCall(tool), timestamp: Date()))
        }
    }

    /// Flattens a hook `tool_input` (untyped JSON) to the `[String: String]` the
    /// chat models use. Cursor's keys (`path`, `command`) are already understood
    /// by `ToolCallItem.inputPreview`, so no key remap is needed here.
    private static func stringInput(_ raw: [String: AnyCodable]?) -> [String: String] {
        guard let raw else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in raw {
            if let s = value.value as? String { out[key] = s }
            else if let i = value.value as? Int { out[key] = String(i) }
            else if let b = value.value as? Bool { out[key] = b ? "true" : "false" }
        }
        return out
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Discovery Processing (GW-194)

    private func processSessionsDiscovered(_ snapshot: [DiscoveredSession]) async {
        let snapshotIds = Set(snapshot.map(\.sessionId))

        // A snapshot is a complete scan: a provisional absent from it aged
        // past the cutoff, lost its transcript, or its agent CLI is gone.
        // Hook-backed sessions have a real lifecycle and are never touched.
        for (id, session) in sessions where session.isProvisional && !snapshotIds.contains(id) {
            sessions.removeValue(forKey: id)
            cancelPendingSync(sessionId: id)
            Self.logger.debug("Pruned stale provisional session \(id.prefix(8), privacy: .public)")
        }

        for discovered in snapshot {
            if var existing = sessions[discovered.sessionId] {
                if existing.isProvisional {
                    existing.lastActivity = discovered.fileModified
                    sessions[discovered.sessionId] = existing
                }
                continue
            }

            // Archived/ended this app run — don't resurrect from the same file
            guard !dismissedSessionIds.contains(discovered.sessionId) else { continue }

            sessions[discovered.sessionId] = SessionState(
                sessionId: discovered.sessionId,
                cwd: discovered.cwd,
                agent: discovered.agent,
                isProvisional: true,
                phase: .idle,
                lastActivity: discovered.fileModified,
                createdAt: discovered.fileModified
            )
            Self.logger.info("Registered provisional \(discovered.agent, privacy: .public) session \(discovered.sessionId.prefix(8), privacy: .public)")

            await adoptConversationInfo(
                sessionId: discovered.sessionId,
                agent: discovered.agent,
                cwd: discovered.cwd
            )
        }
    }

    /// GW-194 / GW-193: parse title/preview when a session is adopted —
    /// idle pre-existing sessions never produce the file-sync events that
    /// normally populate conversationInfo, leaving titles stuck on the
    /// folder name. Parsers cache by mtime, so this is cheap on re-adoption.
    /// Internal for tests (GW-192 precedent).
    func adoptConversationInfo(sessionId: String, agent: String?, cwd: String) async {
        let info: ConversationInfo
        if agent == "codex" {
            info = await CodexTranscriptParser.shared.parse(sessionId: sessionId)
        } else if agent == "cursor" {
            // GW-311: Cursor has no cwd-derivable transcript and writes no
            // summary/ai-title line, so the title comes from its first prompt.
            guard let path = sessions[sessionId]?.transcriptPath, !path.isEmpty else { return }
            info = await CursorTranscriptParser.shared.parse(sessionId: sessionId, transcriptPath: path)
        } else {
            info = await ConversationParser.shared.parse(sessionId: sessionId, cwd: cwd)
        }

        // Re-fetch after the await: the session may have been pruned or
        // upgraded while the parser ran
        guard var session = sessions[sessionId] else { return }

        // Fill-only: a concurrent file sync may have populated richer info
        // while the adoption parse was in flight — never regress it
        let emptyInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        )
        guard session.conversationInfo == emptyInfo else { return }

        session.conversationInfo = info
        sessions[sessionId] = session
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        let agent = sessions[sessionId]?.agent
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
        releaseCursorParserState(sessionId: sessionId, agent: agent)
        dismissedSessionIds.insert(sessionId)
    }

    /// The Cursor parser caches every parsed message per session to serve
    /// incremental reads; drop it when the session goes away so ended sessions
    /// don't accumulate transcripts in memory.
    private func releaseCursorParserState(sessionId: String, agent: String?) {
        guard agent == "cursor" else { return }
        Task { await CursorTranscriptParser.shared.resetState(for: sessionId) }
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // GW-191: Codex history comes from the rollout transcript
        if sessions[sessionId]?.agent == "codex" {
            let conversation = await CodexTranscriptParser.shared.parseConversation(sessionId: sessionId)
            let conversationInfo = await CodexTranscriptParser.shared.parse(sessionId: sessionId)
            await process(.historyLoaded(
                sessionId: sessionId,
                messages: conversation.messages,
                completedTools: conversation.completedToolIds,
                toolResults: conversation.toolResults,
                structuredResults: [:],
                conversationInfo: conversationInfo
            ))
            return
        }

        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        let agent = sessions[sessionId]?.agent

        // GW-311: Cursor writes its transcript lazily and often incompletely, so
        // its chat is built from the hook event stream (see applyCursorHookChat),
        // not a file mirror. Nothing to sync from disk. CursorTranscriptParser is
        // kept as a candidate for later history backfill.
        if agent == "cursor" { return }

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // GW-191: Codex sessions sync from the rollout transcript. Rollouts are
            // small and append-only, so a full (cached-path) reparse is fine — the
            // non-incremental fileUpdated path dedups by stable message ids.
            if agent == "codex" {
                let conversation = await CodexTranscriptParser.shared.parseConversation(sessionId: sessionId)
                guard !conversation.messages.isEmpty else { return }

                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: conversation.messages,
                    isIncremental: false,
                    completedToolIds: conversation.completedToolIds,
                    toolResults: conversation.toolResults,
                    structuredResults: [:]
                )
                await self?.process(.fileUpdated(payload))
                return
            }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
