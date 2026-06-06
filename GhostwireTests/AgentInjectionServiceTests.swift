//
//  AgentInjectionServiceTests.swift
//  GhostwireTests
//
//  GW-164 (C): per-agent injection adapter — pure seams.
//
//  Covers the path-reference formatting (@relative vs @absolute, shell quoting,
//  prefix-boundary safety) and the adapter token construction for Claude/Codex.
//  The CGEvent/paste baseline tier and the live mux send are live-verify only.
//

import XCTest
@testable import Ghostwire

final class AgentInjectionServiceTests: XCTestCase {

    // MARK: - File reference: relative vs absolute

    func testFileUnderCwdBecomesRelative() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/Users/me/project/src/main.swift"),
            sessionCwd: "/Users/me/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@src/main.swift")
    }

    func testFileOutsideCwdStaysAbsolute() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/etc/hosts"),
            sessionCwd: "/Users/me/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@/etc/hosts")
    }

    func testSiblingPrefixIsNotTreatedAsInside() {
        // cwd /a/project must NOT capture /a/project-2/... (string-prefix trap)
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/a/project-2/file.txt"),
            sessionCwd: "/a/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@/a/project-2/file.txt")
    }

    func testNestedFileUnderCwdKeepsFullRelativePath() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/a/project/deep/nested/dir/x.json"),
            sessionCwd: "/a/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@deep/nested/dir/x.json")
    }

    func testTrailingSlashOnCwdIsTolerated() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/a/project/src/x.swift"),
            sessionCwd: "/a/project/",
            adapter: .claude
        )
        XCTAssertEqual(token, "@src/x.swift")
    }

    // MARK: - Shell quoting

    func testRelativePathWithSpaceIsQuoted() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/a/project/My Notes/todo.md"),
            sessionCwd: "/a/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@'My Notes/todo.md'")
    }

    func testAbsolutePathWithSpaceIsQuoted() {
        let token = AgentInjectionService.fileReferenceToken(
            for: URL(fileURLWithPath: "/Users/me/Desktop/Screen Shot.png"),
            sessionCwd: "/a/project",
            adapter: .claude
        )
        XCTAssertEqual(token, "@'/Users/me/Desktop/Screen Shot.png'")
    }

    func testPathWithoutSpaceIsNotQuoted() {
        XCTAssertEqual(
            AgentInjectionService.shellQuoteIfNeeded("src/main.swift"),
            "src/main.swift"
        )
    }

    func testEmbeddedSingleQuoteIsEscaped() {
        // a/it's a/file.txt -> single-quoted with the '\'' idiom
        let quoted = AgentInjectionService.shellQuoteIfNeeded("it's here/file.txt")
        XCTAssertEqual(quoted, "'it'\\''s here/file.txt'")
    }

    // MARK: - relativePath seam directly

    func testRelativePathExactCwdMatchStaysAbsolute() {
        // the file *is* the cwd (no deeper component) -> not a child, absolute
        let path = AgentInjectionService.relativePath(forFile: "/a/project", underCwd: "/a/project")
        XCTAssertEqual(path, "/a/project")
    }

    func testRelativePathEmptyCwdStaysAbsolute() {
        let path = AgentInjectionService.relativePath(forFile: "/a/b/c.txt", underCwd: "")
        XCTAssertEqual(path, "/a/b/c.txt")
    }

    // MARK: - Adapter token construction (Claude / Codex parity)

    func testClaudeAndCodexBothUseAtPrefix() {
        XCTAssertEqual(AgentAdapter.claude.fileReferenceToken(forPath: "src/x.swift"), "@src/x.swift")
        XCTAssertEqual(AgentAdapter.codex.fileReferenceToken(forPath: "src/x.swift"), "@src/x.swift")
    }

    func testAdapterMappingFromAgentTag() {
        XCTAssertEqual(AgentAdapter.forAgentTag("codex"), .codex)
        XCTAssertEqual(AgentAdapter.forAgentTag("Codex"), .codex)
        XCTAssertEqual(AgentAdapter.forAgentTag("claude"), .claude)
        // unknown / nil tags fall back to the shared @path convention
        XCTAssertEqual(AgentAdapter.forAgentTag(nil), .claude)
        XCTAssertEqual(AgentAdapter.forAgentTag("gemini"), .claude)
    }

    func testCodexSessionFormatsSameTokenAsClaude() {
        let url = URL(fileURLWithPath: "/a/project/src/x.swift")
        let claude = AgentInjectionService.fileReferenceToken(for: url, sessionCwd: "/a/project", adapter: .claude)
        let codex = AgentInjectionService.fileReferenceToken(for: url, sessionCwd: "/a/project", adapter: .codex)
        XCTAssertEqual(claude, codex)
        XCTAssertEqual(codex, "@src/x.swift")
    }

    // MARK: - Injection tier selection (pure seam)
    //
    // Tier picks HOW we deliver: an addressable mux pane -> .multiplexer; a
    // plain terminal with a pid -> .baseline (focus + paste); neither -> nil
    // (no deliverable path, which the baseline injector maps to
    // .noDeliverablePath rather than blind-pasting). The actual focus/activation
    // + ⌘V is live-verify only.

    func testTierIsMultiplexerForAddressableCmuxPane() {
        let s = makeSession(id: "cmux", isInCmux: true, ws: "w", surface: "s")
        XCTAssertEqual(AgentTargetResolver.injectionTier(for: s), .multiplexer)
    }

    func testTierIsMultiplexerForAddressableTmuxPane() {
        let s = makeSession(id: "tmux", isInTmux: true, tty: "ttys004")
        XCTAssertEqual(AgentTargetResolver.injectionTier(for: s), .multiplexer)
    }

    func testTierIsBaselineForPlainTerminalWithPid() {
        let s = makeSession(id: "plain", pid: 4321)
        XCTAssertEqual(AgentTargetResolver.injectionTier(for: s), .baseline)
    }

    func testTierIsBaselineWhenMuxRefsMissingButPidPresent() {
        // In cmux per flags but the hook never delivered refs -> not addressable
        // as a pane, but we still have a pid to focus -> baseline, not dropped.
        let s = makeSession(id: "cmuxbad", pid: 4321, isInCmux: true)
        XCTAssertEqual(AgentTargetResolver.injectionTier(for: s), .baseline)
    }

    func testTierIsNilWhenNoPaneAndNoPid() {
        let s = makeSession(id: "orphan", pid: nil)
        XCTAssertNil(AgentTargetResolver.injectionTier(for: s))
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        pid: Int? = 1234,
        isInTmux: Bool = false,
        isInCmux: Bool = false,
        ws: String? = nil,
        surface: String? = nil,
        tty: String? = nil
    ) -> SessionState {
        var session = SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            pid: pid,
            tty: tty,
            isInTmux: isInTmux,
            isInCmux: isInCmux,
            agent: "claude"
        )
        session.cmuxWorkspaceRef = ws
        session.cmuxSurfaceRef = surface
        return session
    }
}
