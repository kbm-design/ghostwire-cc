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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Safety boundary: only these required fields may drop an event.
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        event = try container.decode(String.self, forKey: .event)
        status = try container.decode(String.self, forKey: .status)

        pid = container.decodeLossy(Int.self, forKey: .pid)
        tty = container.decodeLossy(String.self, forKey: .tty)
        tool = container.decodeLossy(String.self, forKey: .tool)
        toolInput = container.decodeToolInput(forKey: .toolInput)
        toolUseId = container.decodeLossy(String.self, forKey: .toolUseId)
        notificationType = container.decodeLossy(String.self, forKey: .notificationType)
        message = container.decodeLossy(String.self, forKey: .message)
        cmuxWorkspace = container.decodeLossy(String.self, forKey: .cmuxWorkspace)
        cmuxSurface = container.decodeLossy(String.self, forKey: .cmuxSurface)
        source = container.decodeLossy(String.self, forKey: .source)
        transcriptPath = container.decodeLossy(String.self, forKey: .transcriptPath)
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

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/com.ghostwire.notch.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
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

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

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
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
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

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
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

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
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

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
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

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            if Self.payloadLooksLikePermissionRequest(data) {
                sendImmediateDeny(
                    to: clientSocket,
                    reason: "Ghostwire could not decode this permission request. Denying so the tool does not run unseen."
                )
            }
            close(clientSocket)
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

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
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                sendImmediateDeny(
                    to: clientSocket,
                    reason: "Ghostwire could not match this permission request to a tool_use_id. Denying so the tool does not run unseen."
                )
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
                closeClientSocket(replacedPending.clientSocket, cleanupPending: true)
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

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = hookResponse(for: pending, decision: decision, reason: reason)
        guard let data = encode(response) else {
            closeClientSocket(pending.clientSocket, cleanupPending: true)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        let writeSuccess = write(data, to: pending.clientSocket)

        if writeSuccess {
            Darwin.close(pending.clientSocket)
        } else {
            closeClientSocket(pending.clientSocket, cleanupPending: true)
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
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

private extension KeyedDecodingContainer where Key == HookEvent.CodingKeys {
    func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func decodeToolInput(forKey key: Key) -> [String: AnyCodable]? {
        if let object = try? decodeIfPresent([String: AnyCodable].self, forKey: key) {
            return object
        }

        guard let string = try? decodeIfPresent(String.self, forKey: key) else {
            return nil
        }

        if let data = string.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            return object
        }

        return ["input": AnyCodable(string)]
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
