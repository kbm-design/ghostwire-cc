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
}
