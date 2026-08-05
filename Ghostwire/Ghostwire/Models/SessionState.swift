//
//  SessionState.swift
//  Ghostwire
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    var isInCmux: Bool
    var cmuxWorkspaceRef: String?
    var cmuxSurfaceRef: String?

    /// Which agent CLI produced this session ("claude" | "codex" | …), from the hook's source tag
    var agent: String?

    /// Authoritative transcript location as reported by the hook (GW-205).
    /// Claude's can be derived from cwd; Cursor's cannot — it lives under
    /// ~/.cursor/projects/<workspace-slug>/agent-transcripts/… (GW-311).
    var transcriptPath: String?

    /// True for sessions registered from a transcript scan (GW-194) that no
    /// hook event has confirmed yet. No pid/tty; pruned when the transcript
    /// falls out of the discovery snapshot; cleared by the first hook event.
    var isProvisional: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    /// GW-311: monotonic id source for Cursor chat items built from hook events
    /// (user prompts + assistant replies, which carry no id of their own). Tool
    /// rows key off tool_use_id instead, so this only covers prose.
    var cursorHookSeq: Int

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        isInCmux: Bool = false,
        agent: String? = nil,
        transcriptPath: String? = nil,
        isProvisional: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        cursorHookSeq: Int = 0,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        // GW-311: an empty cwd yields "/" as the last path component, which read
        // as a session literally titled "/". Fall back to a neutral label until
        // a prompt or summary supplies a real title.
        let derivedName = URL(fileURLWithPath: cwd).lastPathComponent
        self.projectName = projectName
            ?? (derivedName == "/" || derivedName.isEmpty ? "Session" : derivedName)
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.isInCmux = isInCmux
        self.agent = agent
        self.transcriptPath = transcriptPath
        self.isProvisional = isProvisional
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.cursorHookSeq = cursorHookSeq
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    var displayTitle: String {
        conversationInfo.summary ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Short agent label for the row badge ("Claude" / "Codex"); nil if unknown
    var agentLabel: String? {
        guard let agent = agent, !agent.isEmpty else { return nil }
        return agent.prefix(1).uppercased() + agent.dropFirst()
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display (lossy — clipped for compact
    /// rows). Do not use in the verbatim approval path; see `pendingToolRawInput`.
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Verbatim pending tool input — every key/value untruncated, for the
    /// approval surface's full-raw rendering (GW-139 security rule).
    var pendingToolRawInput: String? {
        activePermission?.rawInput
    }

    /// GW-207: single-line command summary for the alert-history row.
    var pendingCommandSummary: String? {
        activePermission?.commandSummary
    }

    /// GW-321 (State B): the pending gate parsed as a Choice, when the tool the
    /// agent is blocked on is `AskUserQuestion`. Nil for every other tool, and
    /// nil if the payload doesn't parse cleanly — callers fall back to the
    /// "answer in the terminal" bar rather than rendering a partial question.
    var pendingChoice: AskUserQuestionRequest? {
        guard let permission = activePermission,
              permission.toolName == "AskUserQuestion",
              let input = permission.toolInput else { return nil }
        return AskUserQuestionRequest(toolInput: input)
    }

    /// GW-322 (State C): the pending gate parsed as a plan review, when the tool
    /// the agent is blocked on is `ExitPlanMode`. Nil for every other tool, and
    /// nil if the payload doesn't parse cleanly — callers fall back to the
    /// verbatim approval bar rather than rendering a plan whose pre-authorized
    /// commands we couldn't read.
    var pendingPlanReview: ExitPlanModeRequest? {
        guard let permission = activePermission,
              permission.toolName == "ExitPlanMode",
              let input = permission.toolInput else { return nil }
        return ExitPlanModeRequest(toolInput: input)
    }

    /// GW-207: project dir last path component, for alert-history rows.
    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session is running in any terminal multiplexer (tmux or cmux)
    var isInMultiplexer: Bool {
        isInTmux || isInCmux
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
