//
//  MCPToolGroupingTests.swift
//  GhostwireTests
//
//  GW-255. The grouping rules were derived from measurement, so the tests pin
//  the measurements rather than the implementation: real annotation shapes
//  observed on five servers, and real tool-name corpora from Linear (57),
//  Paper (34) and server-filesystem (14).
//

import XCTest

@testable import Ghostwire

final class MCPToolGroupingTests: XCTestCase {

    // MARK: - Helpers

    private func tool(
        _ name: String, readOnly: Bool? = nil, destructive: Bool? = nil,
        required: [String] = []
    ) -> MCPToolInfo {
        MCPToolInfo(
            name: name, description: nil, hasOutputSchema: false,
            isReadOnlyHinted: readOnly, isDestructiveHinted: destructive,
            requiredInputs: required)
    }

    // MARK: - Rule 1: the decision tree

    /// The shape actually returned by `@modelcontextprotocol/server-filesystem`
    /// (probed 2026-08-06): read tools carry `readOnlyHint: true` and NO
    /// `destructiveHint` at all. Reading the two as independent booleans would
    /// bucket these as "not declared destructive" and lose the read-only fact.
    func testReadOnlyToolWithAbsentDestructiveHintIsReadOnly() {
        let info = tool("read_file", readOnly: true, destructive: nil)
        XCTAssertEqual(MCPToolClassifier.declaredCapability(for: info), .readOnly)
    }

    func testWritingToolWithDestructiveHintIsDestructive() {
        let info = tool("write_file", readOnly: false, destructive: true)
        XCTAssertEqual(MCPToolClassifier.declaredCapability(for: info), .destructive)
    }

    /// `create_directory` — declares it mutates, declares it isn't destructive.
    func testWritingToolDeclaredNonDestructiveIsWrites() {
        let info = tool("create_directory", readOnly: false, destructive: false)
        XCTAssertEqual(MCPToolClassifier.declaredCapability(for: info), .writes)
    }

    /// Silence is not an upgrade to destructive — most write tools in the wild
    /// omit the hint, and flagging them all as destructive makes the section
    /// meaningless.
    func testWritingToolWithAbsentDestructiveHintIsWritesNotDestructive() {
        let info = tool("save_issue", readOnly: false, destructive: nil)
        XCTAssertEqual(MCPToolClassifier.declaredCapability(for: info), .writes)
    }

    /// No annotations at all → the caller must fall back to the name.
    func testNoAnnotationsYieldsNoDeclaredCapability() {
        XCTAssertNil(MCPToolClassifier.declaredCapability(for: tool("mystery")))
    }

    /// A server contradicting itself gets the stricter reading.
    func testContradictoryAnnotationsResolveToDestructive() {
        let info = tool("purge", readOnly: true, destructive: true)
        XCTAssertEqual(MCPToolClassifier.declaredCapability(for: info), .destructive)
    }

    // MARK: - Inference fallback

    func testVerbInferenceCoversTheCommonShapes() {
        let cases: [(String, MCPToolCapability)] = [
            ("get_issue", .readOnly),
            ("list_issues", .readOnly),
            ("search_documentation", .readOnly),
            ("save_issue", .writes),
            ("create_attachment", .writes),
            ("delete_comment", .destructive),
            ("remove_nodes", .destructive),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(
                MCPToolClassifier.inferredCapability(for: name, serverName: "Linear"), expected,
                "\(name) should infer as \(expected.rawValue)")
        }
    }

    /// Codex adversarial review, 2026-08-06. Inference used to return on the
    /// FIRST recognised verb, so a name that leads with a read verb and then
    /// mutates was classified `.readOnly`. With section-level bulk allow that is
    /// not a badge error — the whole Read-only section goes into `allowedTools`,
    /// which is the gateway's authorization floor, so a mutating tool would have
    /// ridden in on one click.
    func testMixedVerbNamesTakeTheMostDangerousVerbNotTheFirst() {
        let cases: [(String, MCPToolCapability)] = [
            ("get_or_create_issue", .writes),
            ("read_write_file", .writes),
            ("fetch_or_update_record", .writes),
            ("list_and_delete_stale", .destructive),
            ("search_and_purge", .destructive),
            ("get_and_remove_item", .destructive),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(
                MCPToolClassifier.inferredCapability(for: name, serverName: "X"), expected,
                "\(name) must not be inferred read-only")
        }
    }

    /// Destructive outranks writes regardless of token order.
    func testDestructiveOutranksWriteWhicheverComesFirst() {
        XCTAssertEqual(
            MCPToolClassifier.inferredCapability(for: "create_then_delete", serverName: "X"),
            .destructive)
        XCTAssertEqual(
            MCPToolClassifier.inferredCapability(for: "delete_then_create", serverName: "X"),
            .destructive)
    }

    /// The safe direction is preserved: a purely-read name stays read-only.
    func testPurelyReadNamesAreStillReadOnly() {
        for name in ["get_issue", "list_directory_with_sizes", "search_documentation"] {
            XCTAssertEqual(
                MCPToolClassifier.inferredCapability(for: name, serverName: "X"), .readOnly,
                "\(name) should stay read-only")
        }
    }

    /// The measured 2.4% — verb-less names must NOT be silently called readable.
    func testVerbLessNamesAreUnclassifiedRatherThanAssumedSafe() {
        for name in ["ui_evaluate", "ui_fullscreen", "pine_compile"] {
            XCTAssertEqual(
                MCPToolClassifier.inferredCapability(for: name, serverName: "TradingView"),
                .unclassified, "\(name) must not be assumed read-only")
        }
    }

    func testInferenceIsMarkedAsInferredAndDeclarationAsDeclared() {
        let declared = MCPToolClassifier.classify(
            tool: tool("read_file", readOnly: true), serverName: "Filesystem")
        XCTAssertEqual(declared.source, .declared)

        let inferred = MCPToolClassifier.classify(
            tool: tool("read_file"), serverName: "Filesystem")
        XCTAssertEqual(inferred.source, .inferred)
        XCTAssertEqual(inferred.capability, .readOnly)
    }

    // MARK: - Name parsing

    /// Notion prefixes every tool with its own name; `notion-fetch` is a fetch.
    func testServerNamePrefixIsStripped() {
        XCTAssertEqual(
            MCPToolClassifier.nameTokens("notion-create-pages", serverName: "Notion"),
            ["create", "pages"])
    }

    /// A tool whose whole name is the server name keeps it — dropping it would
    /// leave nothing to classify.
    func testServerNamePrefixIsKeptWhenItIsTheWholeName() {
        XCTAssertEqual(
            MCPToolClassifier.nameTokens("notion", serverName: "Notion"), ["notion"])
    }

    /// The singularizer bug the corpus surfaced: `status` → `statu`,
    /// `libraries` → `librarie`. Both read as typos in a section header.
    func testSingularizerLeavesStemSAlone() {
        XCTAssertEqual(MCPToolClassifier.singularized("status"), "status")
        XCTAssertEqual(MCPToolClassifier.singularized("issues"), "issue")
        XCTAssertEqual(MCPToolClassifier.singularized("libraries"), "library")
        XCTAssertEqual(MCPToolClassifier.singularized("nodes"), "node")
    }

    /// A verb-only name has no resource; inventing one produces "Get" and
    /// "List" as sibling categories.
    func testVerbOnlyNameHasNoCategory() {
        XCTAssertNil(MCPToolClassifier.category(for: "whoami", serverName: "Figma"))
        XCTAssertNil(MCPToolClassifier.category(for: "export", serverName: "Paper"))
    }

    func testCategoryIsTheResourceNotTheVerb() {
        XCTAssertEqual(MCPToolClassifier.category(for: "list_issues", serverName: "Linear"), "issue")
        XCTAssertEqual(MCPToolClassifier.category(for: "alert_create", serverName: "TradingView"), "alert")
    }

    // MARK: - Rule 2: adaptive categorization, on real corpora

    /// Linear: measured 95% category coverage — the motivating case.
    func testLinearCorpusCategorizes() {
        let grouping = MCPToolGrouping.build(
            tools: Self.linearTools.map { self.tool($0) }, serverName: "Linear")
        XCTAssertTrue(grouping.isCategorized)
        XCTAssertGreaterThan(grouping.categoryCoverage, 0.9)
        XCTAssertEqual(grouping.totalCount, 57)
    }

    /// Paper: measured 47% — below the floor, so it must stay flat. Category
    /// headers here would be one-per-row, strictly worse than no grouping.
    func testPaperCorpusStaysFlat() {
        let grouping = MCPToolGrouping.build(
            tools: Self.paperTools.map { self.tool($0) }, serverName: "Paper")
        XCTAssertFalse(grouping.isCategorized)
        XCTAssertLessThan(grouping.categoryCoverage, 0.6)
        XCTAssertTrue(grouping.sections.allSatisfy { !$0.isCategorized })
    }

    /// A section whose own categories are all singletons renders flat even when
    /// the server groups: Linear's 4 destructive tools span 4 categories.
    func testSectionWithoutTwoRealGroupsRendersFlatInsideACategorizedServer() {
        let tools = Self.linearTools.map { name -> MCPToolInfo in
            self.tool(name, readOnly: name.hasPrefix("get_") || name.hasPrefix("list_")
                || name.hasPrefix("search_") ? true : false,
                destructive: name.hasPrefix("delete_") ? true : nil)
        }
        let grouping = MCPToolGrouping.build(tools: tools, serverName: "Linear")
        XCTAssertTrue(grouping.isCategorized)

        let destructive = grouping.sections.first { $0.capability == .destructive }
        XCTAssertEqual(destructive?.count, 4)
        XCTAssertFalse(
            destructive?.isCategorized ?? true,
            "4 tools across 4 categories must not render 4 headers over 4 rows")
    }

    /// Singletons collapse into one trailing catch-all rather than a header each.
    func testSingletonCategoriesCollapseIntoATrailingOtherGroup() {
        let grouping = MCPToolGrouping.build(
            tools: Self.linearTools.map { self.tool($0, readOnly: true) }, serverName: "Linear")
        guard let read = grouping.sections.first(where: { $0.capability == .readOnly }) else {
            return XCTFail("expected a read-only section")
        }
        XCTAssertTrue(read.isCategorized)
        XCTAssertEqual(read.categories.last?.isCatchAll, true, "Other must sort last")
        XCTAssertEqual(read.categories.filter(\.isCatchAll).count, 1, "exactly one catch-all")
        XCTAssertTrue(
            read.categories.dropLast().allSatisfy { $0.tools.count >= 2 },
            "every named category carries at least two tools")
    }

    /// A small server is already scannable; headers would be pure overhead.
    func testSmallServerNeverCategorizes() {
        let grouping = MCPToolGrouping.build(
            tools: ["get_item", "get_held_items", "search_saves"].map { self.tool($0) },
            serverName: "Ghostwire")
        XCTAssertFalse(grouping.isCategorized)
    }

    // MARK: - Section invariants

    func testEveryToolLandsInExactlyOneSection() {
        let grouping = MCPToolGrouping.build(
            tools: Self.linearTools.map { self.tool($0) }, serverName: "Linear")
        let placed = grouping.sections.flatMap(\.toolNames)
        XCTAssertEqual(placed.count, Self.linearTools.count)
        XCTAssertEqual(Set(placed), Set(Self.linearTools))
    }

    /// Categorizing must never drop or duplicate a tool relative to its section.
    func testCategoriesPartitionTheirSection() {
        let grouping = MCPToolGrouping.build(
            tools: Self.linearTools.map { self.tool($0) }, serverName: "Linear")
        for section in grouping.sections where section.isCategorized {
            let inCategories = section.categories.flatMap(\.toolNames)
            XCTAssertEqual(
                Set(inCategories), Set(section.toolNames),
                "\(section.capability.rawValue) categories must cover exactly its tools")
            XCTAssertEqual(
                inCategories.count, section.count, "no tool may appear in two categories")
        }
    }

    func testSectionsAreOrderedSafestFirst() {
        let tools = [
            tool("delete_thing", readOnly: false, destructive: true),
            tool("mystery"),
            tool("read_thing", readOnly: true),
            tool("save_thing", readOnly: false),
        ]
        let grouping = MCPToolGrouping.build(tools: tools, serverName: "X")
        XCTAssertEqual(
            grouping.sections.map(\.capability),
            [.readOnly, .writes, .destructive, .unclassified])
    }

    /// An all-inferred section drives the "we guessed these" footer.
    func testEntirelyInferredSectionIsFlagged() {
        let grouping = MCPToolGrouping.build(
            tools: ["read_file", "list_directory"].map { self.tool($0) }, serverName: "Filesystem")
        XCTAssertEqual(grouping.sections.first?.isEntirelyInferred, true)

        let declared = MCPToolGrouping.build(
            tools: ["read_file"].map { self.tool($0, readOnly: true) }, serverName: "Filesystem")
        XCTAssertEqual(declared.sections.first?.isEntirelyInferred, false)
    }

    func testEmptyToolListProducesNoSections() {
        let grouping = MCPToolGrouping.build(tools: [], serverName: "X")
        XCTAssertTrue(grouping.isEmpty)
        XCTAssertFalse(grouping.isCategorized)
    }

    // MARK: - Corpora (real tool names, captured 2026-08-06)

    static let linearTools = [
        "create_attachment", "create_attachment_from_upload", "create_initiative_label",
        "create_issue_label", "delete_attachment", "delete_comment", "delete_diff_comment",
        "delete_status_update", "extract_images", "get_agent_skill", "get_attachment",
        "get_diff", "get_diff_threads", "get_document", "get_initiative", "get_issue",
        "get_issue_status", "get_milestone", "get_project", "get_release", "get_release_note",
        "get_status_updates", "get_team", "get_user", "list_agent_skills", "list_comments",
        "list_cycles", "list_diffs", "list_documents", "list_initiative_labels",
        "list_initiatives", "list_issue_labels", "list_issue_statuses", "list_issues",
        "list_milestones", "list_project_labels", "list_projects", "list_release_notes",
        "list_release_pipelines", "list_releases", "list_teams", "list_users", "merge_diff",
        "prepare_attachment_upload", "resolve_diff_thread", "save_comment", "save_diff_comment",
        "save_document", "save_initiative", "save_issue", "save_milestone", "save_project",
        "save_release", "save_release_note", "save_status_update", "search_documentation",
        "submit_diff_review",
    ]

    static let paperTools = [
        "create_artboard", "create_file", "create_page", "create_tokens", "delete_nodes",
        "duplicate_nodes", "export", "export_combined_pdf", "find_nodes",
        "finish_working_on_nodes", "get_basic_info", "get_children", "get_comment_thread",
        "get_computed_styles", "get_fill_image", "get_font_family_info", "get_guide", "get_jsx",
        "get_node_info", "get_screenshot", "get_selection", "get_tokens", "get_tree_summary",
        "list_comment_thread_authors", "list_comment_threads", "list_files", "move_nodes",
        "open_file", "rename_nodes", "set_comment_thread_status", "set_text_content",
        "set_tokens", "update_styles", "write_html",
    ]
}
