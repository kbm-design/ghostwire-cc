//
//  JSONLInterruptWatcherPathTests.swift
//  GhostwireTests
//
//  GW-205: JSONLInterruptWatcher derived the transcript path from the hook's `cwd`,
//  but Claude keys the projects dir by the session's LAUNCH cwd. A session that
//  enters a worktree mid-flight reports the worktree as `cwd` while its transcript
//  stays under the original project dir, so cwd-derivation pointed at a file that
//  doesn't exist and interrupt detection silently died. The fix prefers the
//  `transcript_path` the hook carries, falling back to cwd-derivation only when absent.
//

import XCTest
@testable import Ghostwire

final class JSONLInterruptWatcherPathTests: XCTestCase {

    func testUsesTranscriptPathWhenProvided() {
        let sessionId = "gw205-explicit-\(UUID().uuidString)"
        let transcript = "/Users/x/.claude/projects/-Users-x-project/\(sessionId).jsonl"

        let watcher = JSONLInterruptWatcher(
            sessionId: sessionId,
            cwd: "/Users/x/project/.worktrees/some-worktree",
            transcriptPath: transcript
        )

        XCTAssertEqual(watcher.filePath, transcript,
                       "An explicit transcript_path must be used verbatim, not re-derived from cwd")
    }

    func testFallsBackToCwdDerivationWhenAbsent() {
        let sessionId = "gw205-fallback-\(UUID().uuidString)"
        let cwd = "/Users/x/project"

        let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd)

        let expected = JSONLInterruptWatcher.transcriptPath(cwd: cwd, sessionId: sessionId)
        XCTAssertEqual(watcher.filePath, expected,
                       "With no transcript_path, the watcher must fall back to cwd-derivation")
    }

    func testEmptyTranscriptPathFallsBackToCwdDerivation() {
        let sessionId = "gw205-empty-\(UUID().uuidString)"
        let cwd = "/Users/x/project"

        let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd, transcriptPath: "")

        let expected = JSONLInterruptWatcher.transcriptPath(cwd: cwd, sessionId: sessionId)
        XCTAssertEqual(watcher.filePath, expected,
                       "An empty transcript_path must be treated as absent")
    }

    func testWorktreeSessionUsesLaunchProjectTranscript() {
        // The live regression: cwd is the worktree, transcript stays under the launch project.
        let sessionId = "gw205-worktree-\(UUID().uuidString)"
        let worktreeCwd = "/Users/me/Coding/repo/.claude/worktrees/gw-162-tmux-pane-targeting"
        let realTranscript = "/Users/me/.claude/projects/-Users-me-Coding-repo/\(sessionId).jsonl"

        let watcher = JSONLInterruptWatcher(
            sessionId: sessionId,
            cwd: worktreeCwd,
            transcriptPath: realTranscript
        )

        XCTAssertEqual(watcher.filePath, realTranscript)
        XCTAssertNotEqual(watcher.filePath,
                          JSONLInterruptWatcher.transcriptPath(cwd: worktreeCwd, sessionId: sessionId),
                          "Worktree cwd-derivation points at a nonexistent file - the bug GW-205 fixes")
    }

    func testHookEventDecodesTranscriptPath() throws {
        let json = """
        {
          "session_id": "abc",
          "cwd": "/Users/x/project/.worktrees/wt",
          "event": "PreToolUse",
          "status": "running_tool",
          "transcript_path": "/Users/x/.claude/projects/-Users-x-project/abc.jsonl"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.transcriptPath, "/Users/x/.claude/projects/-Users-x-project/abc.jsonl")
    }

    func testHookEventTranscriptPathNilWhenAbsent() throws {
        let json = """
        {
          "session_id": "abc",
          "cwd": "/Users/x/project",
          "event": "PreToolUse",
          "status": "running_tool"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertNil(event.transcriptPath,
                     "transcript_path must decode to nil when the hook omits it, triggering cwd fallback")
    }
}
