//
//  HookSocketServer.swift
//  Ghostwire
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Darwin
import Foundation
import os

/// Logger for hook socket server
private let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "Hooks")

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    let cmuxWorkspace: String?
    let cmuxSurface: String?
    let source: String?
    /// Absolute path to the session's JSONL transcript, as reported by the agent hook.
    /// Authoritative for locating the transcript: Claude keys the projects dir by the
    /// session's launch cwd, so a session that enters a worktree mid-flight reports the
    /// worktree as `cwd` while its transcript stays under the original project dir.
    /// Both Claude and Codex send this; falls back to cwd-derivation when absent (GW-205).
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool, source
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case cmuxWorkspace = "cmux_workspace"
        case cmuxSurface = "cmux_surface"
        case transcriptPath = "transcript_path"
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?, cmuxWorkspace: String? = nil, cmuxSurface: String? = nil, source: String? = nil, transcriptPath: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.cmuxWorkspace = cmuxWorkspace
        self.cmuxSurface = cmuxSurface
        self.source = source
        self.transcriptPath = transcriptPath
    }

    /// GW-341: hand-rolled so ONE odd optional field can't drop a whole event.
    ///
    /// The synthesized decoder is all-or-nothing, and Cursor's
    /// `beforeMCPExecution` sends `tool_input` JSON-encoded as a *string*
    /// ("tool_input": "{\"nodeId\":\"1-0\"}"). That threw a typeMismatch, the
    /// event was discarded, and because these events are PermissionRequests the
    /// socket closed with no verdict — the hook fails open and the tool runs
    /// with the human never seeing it. Cursor's hook stream is also its only
    /// source of truth (GW-311), so the session lost its identity too.
    ///
    /// So: the four fields that make an event usable at all still throw;
    /// everything else is best-effort and degrades to nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decode(String.self, forKey: .cwd)
        event = try c.decode(String.self, forKey: .event)
        status = try c.decode(String.self, forKey: .status)

        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
        tty = try? c.decodeIfPresent(String.self, forKey: .tty)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        toolUseId = try? c.decodeIfPresent(String.self, forKey: .toolUseId)
        notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        cmuxWorkspace = try? c.decodeIfPresent(String.self, forKey: .cmuxWorkspace)
        cmuxSurface = try? c.decodeIfPresent(String.self, forKey: .cmuxSurface)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        toolInput = Self.decodeToolInput(from: c)
    }

    /// Accepts `tool_input` as an object (Claude, Codex, Cursor's shell gate) or
    /// as a JSON-encoded string (Cursor's MCP gate). A string that isn't JSON is
    /// kept under `input` rather than dropped — GW-139 says the human approves
    /// what they can see, so losing the payload is worse than labelling it.
    private static func decodeToolInput(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> [String: AnyCodable]? {
        if let object = try? c.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput) {
            return object
        }
        guard let encoded = try? c.decodeIfPresent(String.self, forKey: .toolInput),
              !encoded.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode(
            [String: AnyCodable].self, from: Data(encoded.utf8)
        ) {
            return decoded
        }
        return ["input": AnyCodable(encoded)]
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
    let updatedInput: [String: AnyCodable]?

    init(decision: String, reason: String?, updatedInput: [String: AnyCodable]? = nil) {
        self.decision = decision
        self.reason = reason
        self.updatedInput = updatedInput
    }
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// GW-408: callback for a gate this server refused before it could ever be
/// shown. Separate from `HookEventHandler` because the outcome is already
/// decided — the deny has been written to the hook — so the store must render
/// a finished, non-actionable record, never a live approval bar.
typealias HookGateBlockedHandler = @Sendable (HookEvent, String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/com.ghostwire.notch.sock"

    private var serverSocket: Int32 = -1
    /// GW-414: did *this* process bind the socket path? Only its owner may
    /// unlink it. See `stop()`.
    private var boundSocketPath = false
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var gateBlockedHandler: HookGateBlockedHandler?
    private let queue = DispatchQueue(label: "com.ghostwire.notch.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    /// GW-341: turn a DecodingError into "which field, and what was wrong with
    /// it" — the detail the old warning omitted. `localizedDescription` on a
    /// DecodingError is famously "The data couldn't be read…", which is what
    /// let a systematic drop hide in plain sight.
    static func describe(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.isEmpty ? "<root>" : keys.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let DecodingError.typeMismatch(type, ctx):
            return "field '\(path(ctx.codingPath))' had the wrong type (expected \(type)): \(ctx.debugDescription)"
        case let DecodingError.valueNotFound(type, ctx):
            return "field '\(path(ctx.codingPath))' was null but \(type) is required"
        case let DecodingError.keyNotFound(key, ctx):
            return "required field '\(key.stringValue)' missing at '\(path(ctx.codingPath))'"
        case let DecodingError.dataCorrupted(ctx):
            return "malformed JSON at '\(path(ctx.codingPath))': \(ctx.debugDescription)"
        default:
            return "\(error)"
        }
    }

    /// GW-414: removing a Unix socket path is destructive to whoever owns it,
    /// and the path is a process-wide constant — so ownership has to be checked,
    /// not assumed. Pure and takes its path so it can be tested against a temp
    /// file instead of `/tmp/com.ghostwire.notch.sock`, which on a dev machine
    /// is the live app's socket and precisely what must not be disturbed.
    static func unlinkSocketPathIfOwned(_ path: String, owned: Bool) {
        guard owned else { return }
        unlink(path)
    }

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler,
               onGateBlocked: HookGateBlockedHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onGateBlocked: onGateBlocked)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler,
                             onGateBlocked: HookGateBlockedHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        gateBlockedHandler = onGateBlocked

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")
        // GW-414: from here on, this process is the socket path's owner and is
        // the only one entitled to remove it.
        boundSocketPath = true

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        // GW-414: only remove the socket path if *this* process created it.
        //
        // The unlink used to be unconditional, which made `stop()` destructive
        // from any process that had merely loaded the class. `xcodebuild test`
        // boots the app as its XCTest host: `startMonitoring()` correctly
        // no-ops under XCTest and never binds, but teardown still ran
        // `applicationWillTerminate` -> `stopMonitoring()` -> here, deleting the
        // *live* instance's socket. The live app kept its bound fd and looked
        // healthy, while every new hook connection failed — and every gated
        // tool call then fail-closed denied (GW-413's "socket: none anywhere on
        // disk"). Nothing logged it.
        Self.unlinkSocketPathIfOwned(Self.socketPath, owned: boundSocketPath)
        boundSocketPath = false

        permissionsLock.lock()
        let inFlight = pendingPermissions
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        // GW-408: a bare close() here used to be harmless — the hook read no
        // verdict and exited 0, letting the terminal ask. Since PR #77 made the
        // hook fail closed, closing silently means *quitting Ghostwire denies
        // every tool call currently in flight*. Hand each one back explicitly.
        for (_, pending) in inFlight {
            sendPassthrough(to: pending.clientSocket,
                            reason: "Ghostwire is shutting down and cannot show this request.")
        }
    }

    /// Respond to a pending permission request by toolUseId.
    /// GW-207: `delivered` reports whether the verdict actually reached the
    /// held hook socket - a stale/dead socket means the agent never got it.
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil,
                             delivered: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let ok = self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason) ?? false
            delivered?(ok)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, releasing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        sendPassthrough(to: pending.clientSocket,
                        reason: "This tool was already resolved outside Ghostwire.")
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, _) in matching {
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()

        // GW-408: this fires on every `Stop`, i.e. at the end of every agent
        // turn. Closing with no bytes made the hook fail closed and deny a tool
        // the user was never asked about.
        for (toolUseId, pending) in matching {
            logger.debug("Releasing stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            sendPassthrough(to: pending.clientSocket,
                            reason: "The agent moved on before this request was answered in Ghostwire.")
        }
    }

    private func cleanupPendingPermissions(clientSocket: Int32) {
        permissionsLock.lock()
        let matchingToolUseIds = pendingPermissions.compactMap { toolUseId, pending in
            pending.clientSocket == clientSocket ? toolUseId : nil
        }
        for toolUseId in matchingToolUseIds {
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    private func closeClientSocket(_ clientSocket: Int32, cleanupPending: Bool = false) {
        if cleanupPending {
            cleanupPendingPermissions(clientSocket: clientSocket)
        }
        Darwin.close(clientSocket)
    }

    // MARK: - Tool Use ID Cache

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr = toolInput.map { CanonicalJSON.render($0) } ?? "{}"
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// GW-408: the *shape* of a tool_input — key names only, never values.
    ///
    /// A correlation miss means `PreToolUse` and `PermissionRequest` disagreed
    /// about `tool_input` for the same call, and the old logs said only that a
    /// miss happened, so diagnosing it meant patching the installed hook on a
    /// live machine. Key names are enough to see the disagreement (an object
    /// that arrived JSON-encoded as a string decodes to the single key `input`,
    /// per `decodeToolInput`) and carry none of the command text.
    private static func inputShape(_ toolInput: [String: AnyCodable]?) -> String {
        guard let toolInput else { return "nil" }
        if toolInput.isEmpty { return "{}" }
        return "{" + toolInput.keys.sorted().joined(separator: ",") + "}"
    }

    /// Shapes currently cached for this session+tool — the near-miss set.
    /// Answers "what did we have, and how did it differ from what arrived?"
    private func cachedShapes(sessionId: String, toolName: String?) -> [String] {
        let prefix = "\(sessionId):\(toolName ?? "unknown"):"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return toolUseIdCache.keys
            .filter { $0.hasPrefix(prefix) }
            .map { key -> String in
                let rendered = String(key.dropFirst(prefix.count))
                guard let data = rendered.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return "<unparseable>"
                }
                return "{" + object.keys.sorted().joined(separator: ",") + "}"
            }
            .sorted()
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    /// (internal for unit tests)
    func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public) inputShape:\(Self.inputShape(event.toolInput), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    /// (internal for unit tests)
    func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
        return toolUseId
    }

    /// Evict a tool_use_id from the correlation cache once its tool has run (PostToolUse).
    /// GW-192: without eviction, tools that ran without needing permission (auto-approved)
    /// leave stale ids at the head of the FIFO, and a later PermissionRequest with
    /// identical tool+input correlates to the wrong (already-executed) id.
    func evictCachedToolUseId(_ toolUseId: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        for (key, var queue) in toolUseIdCache {
            if let idx = queue.firstIndex(of: toolUseId) {
                queue.remove(at: idx)
                if queue.isEmpty {
                    toolUseIdCache.removeValue(forKey: key)
                } else {
                    toolUseIdCache[key] = queue
                }
                logger.debug("Evicted executed tool_use_id from cache: \(toolUseId.prefix(12), privacy: .public)")
                return
            }
        }
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        let event: HookEvent
        do {
            event = try JSONDecoder().decode(HookEvent.self, from: data)
        } catch {
            // GW-341: the old message said an event failed but not which field
            // or why, so a systematic Cursor drop went unnoticed for weeks.
            // Name the field and the reason — and say out loud that a dropped
            // PermissionRequest means the hook fails open.
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            // GW-408: this used to say "hook fails open — the tool runs unseen",
            // which stopped being true at PR #77. The hook now denies, so the
            // cost of a drop is a blocked tool, not an unseen one.
            let cost = raw.contains("waiting_for_approval")
                ? "APPROVAL BLOCKED (hook fails closed — the tool is denied)"
                : "telemetry lost"
            logger.error(
                "Dropped hook event: \(cost, privacy: .public) — \(Self.describe(error), privacy: .public) | raw: \(raw, privacy: .public)"
            )
            if Self.payloadLooksLikePermissionRequest(data) {
                let reason = "Ghostwire could not read this permission request (\(Self.describe(error))), so it was blocked rather than run unseen."
                sendImmediateDeny(to: clientSocket, reason: reason)
                // GW-408: PR #77 wrote the deny but told nobody. Surface it, so
                // a blocked tool is something the user can see and re-run.
                gateBlockedHandler?(Self.salvagedGateEvent(from: data), reason)
            }
            close(clientSocket)
            return
        }

        // GW-341: source belongs in this line. Identity bugs are per-event —
        // one mis-sourced event in a stream re-stamps the whole session — and
        // without it there was no way to tell which event did it.
        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public) source=\(event.source ?? "<none>", privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "PostToolUse", let toolUseId = event.toolUseId {
            // The tool ran - its id can no longer be the one a PermissionRequest is about
            evictCachedToolUseId(toolUseId)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                // GW-408: name the disagreement. Session and tool already
                // matched to get here, so a miss means tool_input differed —
                // print both shapes side by side rather than just "no hit".
                let requestShape = Self.inputShape(event.toolInput)
                let cached = cachedShapes(sessionId: event.sessionId, toolName: event.tool)
                logger.warning(
                    "Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) - no cache hit | request inputShape:\(requestShape, privacy: .public) | cached shapes for this session+tool: \(cached.isEmpty ? "<none>" : cached.joined(separator: " "), privacy: .public)"
                )
                let reason = "Ghostwire could not match this \(event.tool ?? "tool") request to the tool call it belongs to, so it was blocked rather than run unseen."
                sendImmediateDeny(to: clientSocket, reason: reason)
                // GW-408: PR #77 removed the `eventHandler?(event)` that used to
                // sit here, so a blocked gate left no trace anywhere in the app —
                // no session row, no history, no signal. Report it as a finished
                // block (never a live gate: the deny is already on the wire).
                gateBlockedHandler?(event, reason)
                close(clientSocket)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message,
                source: event.source,
                transcriptPath: event.transcriptPath
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            let replacedPending = pendingPermissions.updateValue(pending, forKey: toolUseId)
            permissionsLock.unlock()

            if let replacedPending {
                // GW-408: a newer gate resolved to the same toolUseId. The
                // displaced hook is still blocked in recv() — hand it back
                // rather than stranding it into a fail-closed deny.
                logger.debug("Superseded pending permission tool:\(toolUseId.prefix(12), privacy: .public) - releasing the older socket")
                cleanupPendingPermissions(clientSocket: replacedPending.clientSocket)
                sendPassthrough(to: replacedPending.clientSocket,
                                reason: "A newer request replaced this one in Ghostwire.")
            }

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        eventHandler?(event)
    }

    /// Returns whether the verdict was actually written to the held socket (GW-207).
    @discardableResult
    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) -> Bool {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return false
        }
        permissionsLock.unlock()

        let response = hookResponse(for: pending, decision: decision, reason: reason)
        guard let data = encode(response) else {
            closeClientSocket(pending.clientSocket, cleanupPending: true)
            return false
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        let writeSucceeded = write(data, to: pending.clientSocket)

        if writeSucceeded {
            Darwin.close(pending.clientSocket)
        } else {
            closeClientSocket(pending.clientSocket, cleanupPending: true)
        }
        return writeSucceeded
    }

    private func hookResponse(for pending: PendingPermission, decision: String, reason: String?) -> HookResponse {
        let updatedInput: [String: AnyCodable]?
        if decision == "allow", pending.event.tool == "ExitPlanMode" {
            updatedInput = pending.event.toolInput
        } else {
            updatedInput = nil
        }
        return HookResponse(decision: decision, reason: reason, updatedInput: updatedInput)
    }

    private func sendImmediateDeny(to clientSocket: Int32, reason: String) {
        let response = HookResponse(decision: "deny", reason: reason)
        guard let data = encode(response) else { return }
        _ = write(data, to: clientSocket)
    }

    /// GW-408: "Ghostwire is bowing out of this gate — use your own prompt."
    ///
    /// Every path that reaches here is one where Ghostwire *chose* to stop
    /// holding a socket (shutdown, the turn ended, the tool resolved elsewhere,
    /// a newer gate superseded it). None of them is a judgement on the tool, so
    /// none of them should deny it. `ask` is already the documented third value
    /// of `HookResponse.decision`; the hook maps it to exit-0, which is what the
    /// approval path did for every one of these cases before PR #77.
    ///
    /// Closing with zero bytes instead — what this code used to do — is read by
    /// the post-#77 hook as a fail-closed deny.
    private func sendPassthrough(to clientSocket: Int32, reason: String) {
        let response = HookResponse(decision: "ask", reason: reason)
        var wrote = false
        if let data = encode(response) {
            wrote = write(data, to: clientSocket)
        }
        Darwin.close(clientSocket)
        // Logged because the failure mode is silent by construction: an unsent
        // passthrough looks exactly like the zero-byte close it replaced, and
        // the only other evidence is a denial in someone else's terminal.
        if wrote {
            logger.info("Handed gate back to the agent (ask): \(reason, privacy: .public)")
        } else {
            logger.error("FAILED to hand gate back (ask) — the hook will fail closed and deny: \(reason, privacy: .public)")
        }
    }

    /// GW-408: a payload that failed `HookEvent` decoding still usually carries
    /// enough to name what was blocked. Best-effort by design — every field
    /// degrades to a placeholder rather than throwing, because the alternative
    /// is the silent drop this ticket exists to remove.
    private static func salvagedGateEvent(from data: Data) -> HookEvent {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return HookEvent(
            sessionId: object["session_id"] as? String ?? "unknown",
            cwd: object["cwd"] as? String ?? "",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            pid: object["pid"] as? Int,
            tty: object["tty"] as? String,
            tool: object["tool"] as? String ?? object["tool_name"] as? String,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            source: object["source"] as? String,
            transcriptPath: object["transcript_path"] as? String
        )
    }

    private func encode(_ response: HookResponse) -> Data? {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logger.error("Failed to encode hook response: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func write(_ data: Data, to clientSocket: Int32) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return false
            }
            let result = Darwin.write(clientSocket, baseAddress, data.count)
            if result == data.count {
                logger.debug("Write succeeded: \(result) bytes")
                return true
            }
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.error("Short write: \(result) of \(data.count) bytes")
            }
            return false
        }
    }

    private static func payloadLooksLikePermissionRequest(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["event"] as? String == "PermissionRequest"
            || object["hook_event_name"] as? String == "PermissionRequest"
            || object["status"] as? String == "waiting_for_approval"
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}

private enum CanonicalJSON {
    static func render(_ dictionary: [String: AnyCodable]) -> String {
        renderDictionary(dictionary.mapValues(\.value))
    }

    private static func renderValue(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let string as String:
            return renderString(string)
        case let array as [Any]:
            return "[" + array.map(renderValue).joined(separator: ",") + "]"
        case let array as [AnyCodable]:
            return "[" + array.map { renderValue($0.value) }.joined(separator: ",") + "]"
        case let dictionary as [String: Any]:
            return renderDictionary(dictionary)
        case let dictionary as [String: AnyCodable]:
            return renderDictionary(dictionary.mapValues(\.value))
        default:
            return renderString(String(describing: value))
        }
    }

    private static func renderDictionary(_ dictionary: [String: Any]) -> String {
        let pairs = dictionary.keys.sorted().map { key in
            "\(renderString(key)):\(renderValue(dictionary[key] ?? NSNull()))"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    private static func renderString(_ string: String) -> String {
        if let data = try? JSONEncoder().encode(string),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\(string)\""
    }
}
