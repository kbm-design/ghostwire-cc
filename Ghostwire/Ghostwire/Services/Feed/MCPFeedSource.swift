//
//  MCPFeedSource.swift
//  Ghostwire
//
//  GW-214. The Source that turns a connected MCP server into an ambient display
//  feed — with NO LLM anywhere in the loop. This is the "data-in" half of "MCP is
//  the spine" (GW-173 is the "data-out" half), and the strategic half of the feed:
//  GW-261's built-in sources are keyless public APIs, while this one surfaces the
//  servers the user has already authenticated.
//
//  One instance per SERVER, not per tool. The refresh cadence, the connection and
//  the failure posture are all server-scoped, so a server-scoped Source lets one
//  connect attempt cover every card it feeds.
//
//  State policy (GW-285's two card states, applied at the granularity the code
//  actually has):
//    * server unreachable  → ONE "Needs attention" card replacing the set.
//      Every tool is unavailable for the same reason; N copies of it is noise.
//    * one tool fails      → that tool's card becomes "Needs attention", keyed to
//      the SAME card id, so it swaps in place and the user's order never churns.
//    * a connect is already in flight → throw, so FeedSourceCoordinator keeps the
//      previous cards instead of flashing an attention card and back.
//
//  This deliberately reports failure as a card rather than relying on the
//  coordinator's keep-last-good policy, which is source-granular and so cannot
//  express "three tools are fine, the fourth 403s". The timestamp in the footer
//  still carries staleness for the cards that DO hold data.
//

import Foundation
import MCP
import os

// MARK: - Backend seam

/// The slice of `MCPClientService` a feed Source needs.
///
/// A protocol so the state machine and the mapping are testable without a live
/// server — but note what it does NOT add: there is no way to call a tool except
/// `callAllowedTool`, so the feed inherits GW-219's single allowlist choke point
/// rather than opening a side door around it.
@MainActor
protocol MCPFeedBackend: AnyObject, Sendable {
    func feedRuntimeStatus(serverID: UUID) -> MCPServerRuntime.Status
    /// The live tool schema, for checking a binding actually supplies what the
    /// tool requires. Nil before the first successful connect.
    func feedToolInfo(serverID: UUID, tool: String) -> MCPToolInfo?
    /// NON-interactive connect. Must never open a browser: a background refresh
    /// that steals focus for an OAuth grant is precisely the calm-tech violation
    /// this feed exists to avoid. `MCPClientService.connect` satisfies that —
    /// outside `beginInteractiveGrant` the authorizer throws
    /// `MCPAuthInteractionRequired`, which lands as `.needsAuth` and becomes a
    /// card the user can act on when they choose to.
    func connect(id: UUID) async
    func callAllowedTool(serverID: UUID, name: String, arguments: [String: Value]?) async throws
        -> MCPToolCallOutput
}

extension MCPClientService: MCPFeedBackend {
    func feedRuntimeStatus(serverID: UUID) -> MCPServerRuntime.Status {
        runtime(id: serverID)?.status ?? .disconnected
    }

    func feedToolInfo(serverID: UUID, tool: String) -> MCPToolInfo? {
        runtime(id: serverID)?.tools.first { $0.name == tool }
    }
}

extension MCPServerRuntime.Status {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Binding arguments

extension MCPFeedToolBinding {
    /// Parsed arguments, or an empty object when the text isn't a JSON object.
    /// Never throws: a half-typed argument in Settings must degrade to "call it
    /// with no arguments", not kill the whole server's refresh loop.
    func arguments() -> [String: Value] {
        Self.parseArguments(argumentsJSON) ?? [:]
    }

    /// Whether the arguments field holds something usable — drives the inline
    /// error in Settings, where the typo is still fixable.
    var hasValidArguments: Bool {
        argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || Self.parseArguments(argumentsJSON) != nil
    }

    /// Argument keys whose value is still an empty string — i.e. placeholders
    /// the user hasn't filled in.
    ///
    /// `setFeedTool` pre-fills a required tool's shape (`{"query": ""}`) so
    /// Settings can show what's missing. That template is the ONLY thing that
    /// puts an empty string in here, which is what makes this a reliable
    /// "not ready yet" signal rather than a guess.
    var blankArgumentKeys: [String] {
        (Self.parseArguments(argumentsJSON) ?? [:])
            .filter { $0.value.stringValue?.isEmpty == true }
            .keys.sorted()
    }

    /// Required arguments this binding can't satisfy — absent entirely, or
    /// present as an unfilled placeholder.
    ///
    /// Both halves are needed and each was found separately:
    ///  * blank VALUES (`{"query": ""}`) — the pre-filled template, which would
    ///    otherwise poll an empty search every interval against a billing-backed
    ///    API (Codex P2).
    ///  * absent KEYS (`{}`) — what you get by clearing the field, which the
    ///    blank-value check can't see because there's no value to inspect. That
    ///    reached the server and came back as a -32602 on the card, found by
    ///    live-driving.
    ///
    /// `requiredInputs` comes from the live tool schema rather than anything
    /// persisted, so it stays correct if a server changes its signature. When
    /// it's unavailable (not yet connected) this still catches placeholders.
    func missingArguments(requiredInputs: [String]) -> [String] {
        let arguments = arguments()
        var missing = Set(requiredInputs.filter { arguments[$0] == nil })
        missing.formUnion(blankArgumentKeys)
        return missing.sorted()
    }

    static func parseArguments(_ json: String) -> [String: Value]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: Value].self, from: data)
    }
}

// MARK: - Source

struct MCPFeedSource: FeedSource {
    let serverID: UUID
    let serverName: String
    let bindings: [MCPFeedToolBinding]
    let refreshInterval: TimeInterval
    let backend: any MCPFeedBackend

    /// Keyed by the server's persisted UUID, so card ids survive a rename and a
    /// relaunch — renaming a server must not orphan the user's card order.
    var id: String { Self.sourceId(serverID: serverID) }
    var displayName: String { serverName }

    static func sourceId(serverID: UUID) -> String { "mcp.\(serverID.uuidString)" }

    init(
        serverID: UUID,
        serverName: String,
        bindings: [MCPFeedToolBinding],
        refreshInterval: TimeInterval = MCPFeedSource.defaultRefreshInterval,
        backend: any MCPFeedBackend
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.bindings = bindings
        self.refreshInterval = refreshInterval
        self.backend = backend
    }

    /// Five minutes. GW-214 wrote "30–60s", but that was scoped to tickers before
    /// GW-261 shipped a keyless REST path for exactly those. What's left for MCP
    /// is user-authenticated data — issues, builds, balances — which moves on a
    /// human cadence, and every poll here costs a session handshake (and for
    /// stdio, a live subprocess) rather than one stateless GET. Configurable in
    /// Settings for anyone who wants it tighter.
    static let defaultRefreshInterval: TimeInterval = 300

    private static let logger = os.Logger(
        subsystem: "com.ghostwire.notch", category: "MCPFeedSource")

    func fetch() async throws -> [FeedCard] {
        let now = Date()
        var status = await backend.feedRuntimeStatus(serverID: serverID)

        if case .connecting = status {
            // A user-driven connect is in flight (Settings "Test" / "Authorize").
            // Don't race it — the coordinator keeps the previous cards.
            throw MCPFeedSourceError.connectInFlight
        }

        if !status.isConnected {
            // Nothing connects MCP servers at launch, so without this lazy
            // connect every card would read "Connect" until the user happened to
            // open Settings and press Test.
            await backend.connect(id: serverID)
            status = await backend.feedRuntimeStatus(serverID: serverID)
        }

        guard status.isConnected else {
            Self.logger.debug(
                "server \(serverName, privacy: .public) unavailable: \(String(describing: status), privacy: .public)"
            )
            return [
                Self.attentionCard(
                    status: status, serverName: serverName, sourceId: id, now: now)
            ]
        }

        var cards: [FeedCard] = []
        // Sequential: these share one session, and a handful of read calls every
        // few minutes isn't worth a task group.
        for binding in bindings {
            cards.append(await card(for: binding, now: now))
        }
        return cards
    }

    private func card(for binding: MCPFeedToolBinding, now: Date) async -> FeedCard {
        let cardId = "\(id).\(binding.tool)"
        // Never call a tool the binding can't satisfy — that's a guaranteed
        // -32602 on a timer. Say what's missing instead of relaying the
        // server's error code to someone who can't act on it.
        let required = await backend.feedToolInfo(serverID: serverID, tool: binding.tool)?
            .requiredInputs ?? []
        let missing = binding.missingArguments(requiredInputs: required)
        guard missing.isEmpty else {
            return MCPFeedCardMapper.attentionCard(
                id: cardId,
                sourceId: id,
                title: MCPFeedCardMapper.title(tool: binding.tool, serverName: serverName),
                detail: "Set \(missing.joined(separator: ", ")) in Settings › MCP.",
                now: now
            )
        }
        do {
            let output = try await backend.callAllowedTool(
                serverID: serverID, name: binding.tool, arguments: binding.arguments())
            return MCPFeedCardMapper.card(
                from: output,
                tool: binding.tool,
                serverName: serverName,
                id: cardId,
                sourceId: id,
                now: now
            )
        } catch {
            Self.logger.warning(
                "tool \(binding.tool, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return MCPFeedCardMapper.attentionCard(
                id: cardId,
                sourceId: id,
                title: MCPFeedCardMapper.title(tool: binding.tool, serverName: serverName),
                detail: error.localizedDescription,
                now: now
            )
        }
    }

    /// GW-285's "Needs attention", server-wide. `.needsAuth` / `.needsTrust` /
    /// `.failed` / `.disconnected` are ONE state with different words — the copy
    /// is the whole difference, which is why this is a string switch and not four
    /// card shapes.
    static func attentionCard(
        status: MCPServerRuntime.Status,
        serverName: String,
        sourceId: String,
        now: Date
    ) -> FeedCard {
        MCPFeedCardMapper.attentionCard(
            id: "\(sourceId).server",
            sourceId: sourceId,
            title: serverName,
            detail: attentionCopy(for: status),
            now: now
        )
    }

    static func attentionCopy(for status: MCPServerRuntime.Status) -> String {
        switch status {
        case .needsAuth: return "Sign in to this server in Settings › MCP."
        case .needsTrust: return "Trust this server's command in Settings › MCP."
        case .failed(let reason): return reason
        case .disconnected: return "Not connected — connect it in Settings › MCP."
        case .connecting: return "Connecting…"
        case .connected: return "Connected."
        }
    }
}

enum MCPFeedSourceError: Error, Equatable {
    /// A user-driven connect is already running; skip this refresh.
    case connectInFlight
}

// MARK: - Result → card

/// Pure: one tool result → one card. This function IS the GW-214 seam —
/// everything above it is transport, everything below it is rendering, and the
/// card layer still never learns an MCP server was involved.
///
/// The mapping is inferred from the payload's SHAPE, which is a deliberate
/// stopgap: GW-328 Phase 3 makes source→kind a declared, user-confirmed mapping
/// (with `outputSchema` as a hint). Until then, guessing well beats rendering
/// nothing — every rule below degrades toward `.text`, and `.generic` is never
/// blocked.
enum MCPFeedCardMapper {
    /// The renderer shows 3 rows + "+N more". Carrying a few extra keeps that
    /// count honest without hauling a whole issue tracker into memory per poll.
    static let maxListItems = 12

    /// Field preference for one list row. `title` leads because that is what
    /// every issue tracker, feed and document store calls its human-readable
    /// line. This ordering is the seed of GW-328 Phase 3's declared mapping.
    static let rowKeys = [
        "title", "name", "summary", "label", "headline", "subject", "text",
        "description", "identifier", "id",
    ]

    static func card(
        from output: MCPToolCallOutput,
        tool: String,
        serverName: String,
        id: String,
        sourceId: String,
        now: Date
    ) -> FeedCard {
        FeedCard(
            id: id,
            sourceId: sourceId,
            kind: kind(from: output, tool: tool, serverName: serverName),
            updatedAt: now
        )
    }

    static func attentionCard(
        id: String, sourceId: String, title: String, detail: String, now: Date
    ) -> FeedCard {
        // `.generic` because the four shipped kinds have no attention treatment
        // yet — GW-285 owns the visual, GW-328 may promote this to `.status`.
        // One line of copy, no data: the shape the design brief asks for, minus
        // the button it hasn't specified.
        FeedCard(
            id: id,
            sourceId: sourceId,
            kind: .generic(title: title, subtitle: detail, value: nil),
            updatedAt: now
        )
    }

    static func kind(from output: MCPToolCallOutput, tool: String, serverName: String)
        -> FeedCardKind {
        let heading = title(tool: tool, serverName: serverName)

        // A server reporting its own failure is Needs attention, not data.
        if output.isError == true {
            return .generic(
                title: heading,
                subtitle: firstLine(output.textRepresentation) ?? "The server reported an error.",
                value: nil
            )
        }

        // structuredContent is the typed path — the only one that can yield a
        // number or a list without guessing at prose.
        if let structured = output.structuredContent,
            let kind = kind(from: structured, heading: heading) {
            return kind
        }

        let text = output.textRepresentation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Reached the end with nothing to show. Not an error — the tool ran.
            return .generic(title: heading, subtitle: "No data", value: nil)
        }

        // Many servers still return their payload as a JSON string in a text
        // block instead of `structuredContent` — patchy `outputSchema` adoption
        // is GW-214's own named gating risk. Re-parse before giving up on shape.
        if let data = text.data(using: .utf8),
            let value = try? JSONDecoder().decode(Value.self, from: data),
            let kind = kind(from: value, heading: heading) {
            return kind
        }

        return .text(title: heading, body: text)
    }

    /// Format-driven, ordered so the least information is lost: a collection
    /// stays a collection, a number stays a number, and anything with no
    /// recognisable shape returns nil so the caller can fall back to prose.
    static func kind(from value: Value, heading: String) -> FeedCardKind? {
        switch value {
        case .array(let elements):
            return list(elements, heading: heading)

        case .object(let object):
            // The KV shape GW-214 names explicitly: {"label": …, "value": …}.
            if let label = object["label"]?.stringValue,
                let text = object["value"].flatMap(scalarText) {
                return .data(label: label, value: text, delta: object["delta"].flatMap(scalarText))
            }
            // The wrapper servers use to name a collection — {"issues": [...]},
            // {"results": [...]}. The array is the content; unwrap it.
            if let elements = soleArray(in: object) {
                return list(elements, heading: heading)
            }
            let scalars = object.compactMapValues(scalarText)
            guard !scalars.isEmpty else { return nil }
            if scalars.count == 1, let text = scalars.values.first {
                // One number is a metric. The key is nearly always a restatement
                // of the tool name, and the heading carries the provenance the
                // footer glyph can't (hosted MCP servers have no local app icon
                // to resolve — §3 of the GW-285 design reference).
                return .data(label: heading, value: text, delta: nil)
            }
            return .list(
                title: heading,
                items: scalars.keys.sorted().prefix(maxListItems).map { "\($0): \(scalars[$0]!)" }
            )

        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(title: heading, body: trimmed)

        case .int, .double, .bool:
            return scalarText(value).map { .data(label: heading, value: $0, delta: nil) }

        case .null, .data:
            return nil
        }
    }

    /// Rows from an array.
    ///
    /// An EMPTY collection renders as a count, not an attention state: per the
    /// GW-285 brief, "no issues assigned to you" is a success whose value happens
    /// to be zero, and belongs inside Has data.
    static func list(_ elements: [Value], heading: String) -> FeedCardKind {
        let items = elements.prefix(maxListItems).compactMap(row(for:))
        guard !items.isEmpty else {
            return .data(label: heading, value: "\(elements.count)", delta: nil)
        }
        return .list(title: heading, items: items)
    }

    /// Keys that hold a SHORT human-facing handle alongside a title — Linear
    /// `identifier`/`id` ("GW-332"), Jira `key` ("PROJ-123"), GitHub `number`,
    /// Sentry `shortId`. Not vendor-specific: these are the spellings trackers
    /// converged on, and `maxHandleLength` is what actually does the filtering —
    /// a UUID or a database row id is never a useful prefix.
    static let handleKeys = ["identifier", "key", "shortId", "number", "id"]
    static let maxHandleLength = 12

    /// One row's text. An element with a known human field uses it, prefixed by
    /// its handle when it has one — "GW-332 MCP server add-flow" survives
    /// truncation far better than either half alone, which matters because the
    /// card truncates every row.
    ///
    /// This is the ceiling for guessing. GW-328 Phase 3 replaces it with a
    /// DECLARED source→field mapping; extending the heuristic further would
    /// just be more to delete.
    ///
    /// Per-item links are deliberately NOT modelled: `.list` can't carry them
    /// yet, and that's GW-328 Phase 1's to add.
    static func row(for element: Value) -> String? {
        if let text = scalarText(element) { return text }
        guard let object = element.objectValue else { return nil }

        let handle = handle(in: object)
        for key in rowKeys {
            guard let text = object[key].flatMap(scalarText) else { continue }
            // Never prefix a value with itself (an object whose only field IS
            // the handle).
            guard let handle, handle != text else { return text }
            return "\(handle) \(text)"
        }
        // No known field: the handle, else the first scalar — either beats
        // rendering nothing.
        return handle
            ?? object.keys.sorted().lazy.compactMap { object[$0].flatMap(scalarText) }.first
    }

    static func handle(in object: [String: Value]) -> String? {
        for key in handleKeys {
            guard let text = object[key].flatMap(scalarText),
                text.count <= maxHandleLength
            else { continue }
            return text
        }
        return nil
    }

    /// The array in an object that holds exactly one. Two collections in one
    /// payload is genuinely ambiguous — better to fall through to the scalars
    /// (often a total) than to pick one arbitrarily.
    static func soleArray(in object: [String: Value]) -> [Value]? {
        let arrays = object.values.compactMap(\.arrayValue)
        return arrays.count == 1 ? arrays.first : nil
    }

    /// One JSON scalar as display text. Objects and arrays return nil on
    /// purpose: a card reading "[object Object]" is worse than one that degrades.
    static func scalarText(_ value: Value) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int(let number):
            return FeedValueFormatter.count(number)
        case .double(let number):
            return FeedValueFormatter.number(number)
        case .bool(let flag):
            return flag ? "Yes" : "No"
        case .null, .array, .object, .data:
            return nil
        }
    }

    /// "Linear · List Issues" — the server names the provenance the footer glyph
    /// can't, and the tool names the content.
    static func title(tool: String, serverName: String) -> String {
        let readable = readableToolName(tool)
        return serverName.isEmpty ? readable : "\(serverName) · \(readable)"
    }

    /// Tool names arrive as `snake_case`, `kebab-case` or `camelCase`; all three
    /// become words. Not `MCPToolFormatter.toTitleCase`, which lowercases each
    /// token's tail and so turns `getUserInfo` into "Getuserinfo" — correct for
    /// its own callers, wrong for a card heading.
    static func readableToolName(_ tool: String) -> String {
        var words: [String] = []
        var current = ""
        for character in tool {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (line?.isEmpty ?? true) ? nil : line
    }
}
