//
//  MCPToolGrouping.swift
//  Ghostwire
//
//  GW-255: turns a flat `[MCPToolInfo]` into the sectioned, bulk-selectable
//  shape the allowlist renders. Pure — no SwiftUI, no service, no I/O — so the
//  rules below are unit-testable rather than buried in a view body (§8.4:
//  "shape it as data, not view code").
//
//  This grouping is ALSO the curation surface for GW-184's exposure model:
//  `allowedTools` is the gateway's authorization floor (`gatewayServers()`
//  filters by it; `MCPClientServiceUpstreamSource.call` routes through
//  `callAllowedTool`), so what gets allowed here is exactly what an external
//  chat app can reach via `call_tool`. There is no second gate. Treat the
//  sections as product, not chrome.
//
//  ─── The two rules, and the measurements behind them ──────────────────────
//
//  1. CAPABILITY IS A DECISION TREE, NOT TWO FLAGS. Probed 5 real servers
//     (Exa over HTTP; server-filesystem / -memory / -everything /
//     -sequential-thinking over stdio, 2026-08-06): `readOnlyHint` was set on
//     39/39 tools, but `destructiveHint` appears ONLY where `readOnlyHint` is
//     false — `read_file` carries no `destructiveHint` at all, because the
//     field is meaningless for a tool that doesn't mutate. So read them in
//     order. Treating them as independent booleans puts read-only tools in the
//     "not declared destructive" bucket and reads as a missing annotation.
//
//  2. CATEGORY GROUPING IS ADAPTIVE, BECAUSE IT ISN'T ALWAYS VIABLE. Measured
//     over 246 real tool names from 8 servers: the share of tools landing in a
//     category with 2+ members is Linear 95%, TradingView 81%, Raindrop 77% —
//     but Notion 52%, Figma 52%, Paper 47%. Below the threshold nearly every
//     category is a header over a single row, which is strictly worse than a
//     flat list. So sub-grouping switches itself on per server.
//
//  Annotations are UI bias only, never a security boundary — the allowlist is
//  enforced in `MCPClientService.callAllowedTool`.
//

import Foundation

// MARK: - Capability

/// What calling a tool does. The primary axis of the allowlist, always shown.
enum MCPToolCapability: String, CaseIterable, Identifiable, Equatable, Sendable {
    case readOnly
    case writes
    case destructive
    /// Neither annotated nor inferable. Its own section on purpose: folding a
    /// tool nobody could classify into `readOnly` is a security-relevant lie,
    /// and 2.4% of the measured corpus lands here.
    case unclassified

    var id: String { rawValue }

    /// Section title. Sentence case, because it heads a list, not a button.
    var sectionTitle: String {
        switch self {
        case .readOnly: return "Read-only"
        case .writes: return "Writes"
        case .destructive: return "Destructive"
        case .unclassified: return "Not classified"
        }
    }

    /// The per-row badge. Matches the labels GW-219 already shipped so the
    /// vocabulary doesn't fork.
    var badge: String {
        switch self {
        case .readOnly: return "read-only"
        case .writes: return "writes"
        case .destructive: return "destructive"
        case .unclassified: return "unknown"
        }
    }

    /// Whether allowing this reaches beyond reading. Drives the one consequence
    /// line per §8.5 — and `unclassified` counts, because an unknown tool is
    /// not a safe tool.
    var mutates: Bool { self != .readOnly }

    /// Display order — safest first, so the section a user most likely wants to
    /// bulk-allow is the one they reach without scrolling.
    static let displayOrder: [MCPToolCapability] = [
        .readOnly, .writes, .destructive, .unclassified,
    ]

    /// Which SECTION this capability renders under.
    ///
    /// `writes` and `destructive` share one, because the split misled: the
    /// write lexicon holds `update`, `set`, `edit`, `merge`, `move` and
    /// `rename` — so "Write" sounded additive while containing every way to
    /// overwrite your work, and "Destructive" implied it was the only dangerous
    /// one. Keelan caught it (2026-08-21). Anything that isn't read-only is now
    /// one bucket.
    ///
    /// Nothing is lost where it counts: the per-row BADGE still says `writes`
    /// vs `destructive` on the individual toggle, and bulk-allow was already
    /// read-only-only, so merging changes no permission behaviour at all.
    var section: MCPToolSection {
        switch self {
        case .readOnly: return .read
        case .writes, .destructive: return .write
        case .unclassified: return .other
        }
    }
}

/// The three sections the allowlist renders. Coarser than `MCPToolCapability`
/// on purpose — this is the grouping, that is the claim.
enum MCPToolSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case read
    case write
    /// Neither annotated nor inferable. Its own section on purpose: folding a
    /// tool nobody could classify into `read` is a security-relevant lie.
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .other: return "Other"
        }
    }

    static let displayOrder: [MCPToolSection] = [.read, .write, .other]
}

/// Where a capability came from. Surfaced in the UI because "the server told
/// us" and "we guessed from the name" are different promises, and the user is
/// making a security decision on the strength of one of them.
enum MCPCapabilitySource: Equatable {
    /// The server declared `readOnlyHint` / `destructiveHint`.
    case declared
    /// Derived from the tool's verb because the server declared nothing.
    case inferred
}

// MARK: - Classification

enum MCPToolClassifier {
    /// Verb lexicons. Deliberately generous on `read`: a false "writes" is a
    /// nuisance (the user allows it by hand), a false "read-only" is a lie the
    /// user acts on. Unknown verbs fall through to `.unclassified` rather than
    /// defaulting to anything.
    static let readVerbs: Set<String> = [
        "get", "list", "find", "search", "fetch", "read", "query", "view", "describe",
        "info", "status", "check", "analyze", "export", "download", "whoami",
        "resolve", "show", "quote", "depth", "count", "inspect", "diff", "summarize",
        "validate", "lookup",
    ]

    static let writeVerbs: Set<String> = [
        "create", "add", "update", "set", "save", "upload", "send", "move", "rename",
        "duplicate", "submit", "merge", "new", "open", "start", "switch", "toggle",
        "run", "exec", "write", "prepare", "batch", "click", "type", "scroll",
        "hover", "draw", "trade", "use", "generate", "manage", "autoplay", "step",
        "replay", "finish", "import", "install", "apply", "edit", "post", "publish",
        "assign", "invite", "sync", "push", "insert", "append", "copy", "convert",
    ]

    static let destructiveVerbs: Set<String> = [
        "delete", "remove", "clear", "close", "drop", "purge", "reset", "revoke",
        "cancel", "end", "kill", "stop", "uninstall", "archive", "unlink", "destroy",
        "truncate", "wipe", "prune", "detach", "disconnect",
    ]

    /// Rule 1 above: annotations read as a decision tree.
    ///
    /// Returns `nil` when the server declared nothing at all, so the caller can
    /// fall back to the name and mark the result `.inferred`. Note the two
    /// annotations are checked in order — a `destructiveHint` on a tool that
    /// also says `readOnlyHint: true` is a server contradicting itself, and we
    /// believe the stricter claim.
    static func declaredCapability(for tool: MCPToolInfo) -> MCPToolCapability? {
        if tool.isDestructiveHinted == true { return .destructive }
        if tool.isReadOnlyHinted == true { return .readOnly }
        if tool.isReadOnlyHinted == false {
            // It mutates. `destructiveHint: false` means "not destructive";
            // absent means the server didn't say, and we don't upgrade silence
            // to destructive — that would flag most write tools in the wild.
            return .writes
        }
        return nil
    }

    /// Verb inference. 97.6% coverage on the measured 246-name corpus; the
    /// misses are verb-less UI helpers (`ui_evaluate`, `pine_compile`), which
    /// correctly land in `.unclassified`.
    ///
    /// **Scans every token and keeps the most dangerous** — it must not return
    /// on the first verb it recognises. `get_or_create_issue` and
    /// `read_write_file` both lead with a read verb and then mutate; returning
    /// early classified them `.readOnly`, and with section-level bulk allow that
    /// is not a cosmetic badge error — the whole Read-only section goes into
    /// `allowedTools`, which is the gateway's authorization floor. A tool that
    /// mutates would have ridden in on one click.
    ///
    /// The asymmetry is deliberate: a false "destructive" costs the user one
    /// manual toggle, a false "read-only" silently grants a mutating capability.
    /// Measured cost on the 246-name corpus: **3 names change, all of them to a
    /// stricter class** (`draw_clear`, `draw_remove_one`, `replay_stop`), and
    /// the unclassified share is unchanged at 2.4%.
    static func inferredCapability(for name: String, serverName: String) -> MCPToolCapability {
        var strongest: MCPToolCapability?
        for token in nameTokens(name, serverName: serverName) {
            if destructiveVerbs.contains(token) {
                return .destructive  // nothing outranks this, so stop
            }
            if writeVerbs.contains(token) {
                strongest = .writes
            } else if readVerbs.contains(token), strongest == nil {
                strongest = .readOnly
            }
        }
        return strongest ?? .unclassified
    }

    static func classify(
        tool: MCPToolInfo, serverName: String
    ) -> (capability: MCPToolCapability, source: MCPCapabilitySource) {
        if let declared = declaredCapability(for: tool) { return (declared, .declared) }
        return (inferredCapability(for: tool.name, serverName: serverName), .inferred)
    }

    // MARK: Name parsing

    /// Split on both separators — servers use `_` (Linear) and `-` (Notion) —
    /// and drop a leading copy of the server's own name, because
    /// `notion-create-pages` is `create pages`, not a tool about Notion.
    static func nameTokens(_ name: String, serverName: String) -> [String] {
        var parts = name.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(String.init)
        let slug = serverName.lowercased().filter { !$0.isWhitespace }
        if let first = parts.first, first == slug, parts.count > 1 { parts.removeFirst() }
        return parts
    }

    /// The resource the tool acts on: the first token that isn't the verb.
    ///
    /// Returns `nil` when the name is only a verb (`export`, `whoami`) — those
    /// have no resource, and inventing one from the verb is how "Get", "List"
    /// and "Search" end up as sibling categories.
    static func category(for name: String, serverName: String) -> String? {
        let parts = nameTokens(name, serverName: serverName)
        guard parts.count > 1 else { return nil }
        var verbIndex: Int?
        for (index, token) in parts.enumerated()
        where destructiveVerbs.contains(token) || writeVerbs.contains(token)
            || readVerbs.contains(token) {
            verbIndex = index
            break
        }
        let rest = parts.enumerated().filter { $0.offset != verbIndex }.map(\.element)
        guard let head = rest.first else { return nil }
        return singularized(head)
    }

    /// Naive `-s` stripping turns `status` into `statu` and `libraries` into
    /// `librarie`, which then read as typos in a section header. Handle the two
    /// shapes that actually occur and leave everything else alone.
    static func singularized(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"
        }
        // `status`, `analysis`, `css` — an `s` after `s`/`u` is part of the stem.
        if word.hasSuffix("s"), word.count > 3 {
            let penultimate = word[word.index(word.endIndex, offsetBy: -2)]
            if penultimate != "s" && penultimate != "u" { return String(word.dropLast()) }
        }
        return word
    }

    /// Title for a category header. `issue` → `Issues`, and it stays plural
    /// because the header labels a set.
    static func categoryTitle(_ category: String) -> String {
        let plural = category.hasSuffix("y")
            ? String(category.dropLast()) + "ies"
            : (category.hasSuffix("s") ? category : category + "s")
        return plural.prefix(1).uppercased() + plural.dropFirst()
    }
}

// MARK: - The grouped shape

/// One tool, classified.
struct MCPGroupedTool: Identifiable, Equatable {
    let tool: MCPToolInfo
    let capability: MCPToolCapability
    let source: MCPCapabilitySource

    var id: String { tool.name }
    var name: String { tool.name }
}

/// A resource sub-group inside a capability section. Only ever built when the
/// adaptive rule says categories are worth showing.
struct MCPToolCategoryGroup: Identifiable, Equatable {
    /// Stable slug (`issue`), or `nil` for the trailing catch-all.
    let category: String?
    let title: String
    let tools: [MCPGroupedTool]

    var id: String { category ?? "\u{0000}other" }
    var toolNames: [String] { tools.map(\.name) }
    /// The catch-all is never offered a bulk control — "Allow all 6 unrelated
    /// things" isn't a meaningful action.
    var isCatchAll: Bool { category == nil }

    func canBulkAllow(in section: MCPCapabilitySection) -> Bool {
        section.canBulkAllow && !isCatchAll
    }
}

/// One capability section: always present when non-empty, sub-grouped only when
/// this section itself has enough structure to justify it.
struct MCPCapabilitySection: Identifiable, Equatable {
    let kind: MCPToolSection
    let tools: [MCPGroupedTool]
    /// Empty when this section renders flat.
    let categories: [MCPToolCategoryGroup]

    var id: String { kind.rawValue }

    /// The most dangerous capability present. The consequence line must speak
    /// for the WORST member, not the first — a section holding one `delete`
    /// among nine `update`s is a delete section.
    var severestCapability: MCPToolCapability {
        if tools.contains(where: { $0.capability == .destructive }) { return .destructive }
        if tools.contains(where: { $0.capability == .unclassified }) { return .unclassified }
        if tools.contains(where: { $0.capability == .writes }) { return .writes }
        return .readOnly
    }
    var isCategorized: Bool { !categories.isEmpty }
    var toolNames: [String] { tools.map(\.name) }
    var count: Int { tools.count }
    /// Every section takes a bulk Allow all / Remove all (Keelan, 2026-08-25).
    /// This was read-only-only from GW-255 until then; the section title now
    /// carries the warning and the per-tool toggle is still where the finer
    /// decision lives. Kept as a property so a future narrowing is one line.
    var canBulkAllow: Bool { true }
    /// True when every tool here was guessed from its name — drives the section
    /// footer that says so.
    var isEntirelyInferred: Bool {
        !tools.isEmpty && tools.allSatisfy { $0.source == .inferred }
    }
}

/// The whole allowlist, ready to render.
struct MCPToolGrouping: Equatable {
    let sections: [MCPCapabilitySection]
    /// Whether the server's names carried enough structure to sub-group.
    let isCategorized: Bool
    /// Share of tools in a multi-member category — surfaced for tests and for
    /// the diagnostic footer, not shown as a number to the user.
    let categoryCoverage: Double

    var isEmpty: Bool { sections.isEmpty }
    var totalCount: Int { sections.reduce(0) { $0 + $1.count } }

    // MARK: Thresholds

    /// A server groups only if at least this many categories have 2+ members…
    static let minimumMultiMemberCategories = 2
    /// …and they account for at least this share of its tools.
    static let minimumCategoryCoverage = 0.6
    /// Below this, sub-headers cost more rows than they save. A 6-tool server
    /// is already scannable.
    static let minimumToolsToCategorize = 12

    // MARK: Build

    static func build(tools: [MCPToolInfo], serverName: String) -> MCPToolGrouping {
        guard !tools.isEmpty else {
            return MCPToolGrouping(sections: [], isCategorized: false, categoryCoverage: 0)
        }

        let classified = tools.map { tool -> MCPGroupedTool in
            let (capability, source) = MCPToolClassifier.classify(tool: tool, serverName: serverName)
            return MCPGroupedTool(tool: tool, capability: capability, source: source)
        }

        // Rule 2, evaluated across the WHOLE server: a server either has a
        // resource spine or it doesn't, and deciding per section would let
        // Read-only group while Writes didn't for the same vocabulary.
        var membership: [String: Int] = [:]
        for item in classified {
            guard let category = MCPToolClassifier.category(
                for: item.name, serverName: serverName) else { continue }
            membership[category, default: 0] += 1
        }
        let multiMember = membership.filter { $0.value >= 2 }
        let covered = multiMember.values.reduce(0, +)
        let coverage = Double(covered) / Double(classified.count)
        let shouldCategorize = classified.count >= minimumToolsToCategorize
            && multiMember.count >= minimumMultiMemberCategories
            && coverage >= minimumCategoryCoverage

        var sections: [MCPCapabilitySection] = []
        for kind in MCPToolSection.displayOrder {
            let members = classified.filter { $0.capability.section == kind }
            guard !members.isEmpty else { continue }
            let categories = shouldCategorize
                ? categorized(members, serverName: serverName, multiMember: Set(multiMember.keys))
                : []
            sections.append(
                MCPCapabilitySection(
                    kind: kind,
                    // Within the merged Write section, destructive tools sort
                    // LAST — the ones you are least likely to want are the ones
                    // you should have to travel furthest to switch on.
                    // Within the merged Write section, destructive tools sort
                    // LAST — the ones you are least likely to want are the ones
                    // you should have to travel furthest to switch on.
                    tools: members.sorted(by: severityThenName),
                    categories: categories))
        }

        return MCPToolGrouping(
            sections: sections, isCategorized: shouldCategorize, categoryCoverage: coverage)
    }

    /// Build the sub-groups for one capability section.
    ///
    /// Two guards worth keeping: singletons collapse into one trailing "Other"
    /// rather than each getting a header, and a section that ends up with fewer
    /// than two real groups renders flat — Linear's 4 Destructive tools span 4
    /// categories, so categorizing them would produce four headers over four
    /// rows inside a server that otherwise groups beautifully.
    /// Severity first, then name.
    ///
    /// Used by the flat path AND by every category group. Having the sort in
    /// only one of them was a real defect (Codex, 2026-08-21): the section-level
    /// sort put destructive tools last, then `categorized()` re-sorted by name
    /// and threw it away — so on Linear, which categorizes 95% of its tools,
    /// `delete_issue` landed between `create_issue` and `get_issue`. The
    /// ordering matters most exactly where it was being discarded.
    static func severityThenName(_ a: MCPGroupedTool, _ b: MCPGroupedTool) -> Bool {
        if a.capability != b.capability {
            let order = MCPToolCapability.displayOrder
            return (order.firstIndex(of: a.capability) ?? order.count)
                < (order.firstIndex(of: b.capability) ?? order.count)
        }
        return a.name < b.name
    }

    private static func categorized(
        _ members: [MCPGroupedTool], serverName: String, multiMember: Set<String>
    ) -> [MCPToolCategoryGroup] {
        var buckets: [String: [MCPGroupedTool]] = [:]
        var leftovers: [MCPGroupedTool] = []
        for item in members {
            guard let category = MCPToolClassifier.category(for: item.name, serverName: serverName),
                multiMember.contains(category)
            else {
                leftovers.append(item)
                continue
            }
            buckets[category, default: []].append(item)
        }

        // A category with a single member *inside this section* is a singleton
        // here even if the server has more of them elsewhere.
        for (category, items) in buckets where items.count == 1 {
            leftovers.append(contentsOf: items)
            buckets[category] = nil
        }

        guard buckets.count >= 2 else { return [] }

        var groups: [MCPToolCategoryGroup] = []
        for (category, items) in buckets {
            let sorted: [MCPGroupedTool] = items.sorted(by: severityThenName)
            groups.append(
                MCPToolCategoryGroup(
                    category: category,
                    title: MCPToolClassifier.categoryTitle(category),
                    tools: sorted))
        }
        // Biggest first — the group most worth bulk-allowing leads. Ties break
        // alphabetically so the order is stable across launches.
        groups.sort { lhs, rhs in
            lhs.tools.count == rhs.tools.count
                ? lhs.title < rhs.title
                : lhs.tools.count > rhs.tools.count
        }

        if !leftovers.isEmpty {
            groups.append(
                MCPToolCategoryGroup(
                    category: nil, title: "Other",
                    tools: leftovers.sorted { $0.name < $1.name }))
        }
        return groups
    }
}
