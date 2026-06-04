//
//  SessionDiscoveryStoreTests.swift
//  GhostwireTests
//
//  GW-194: provisional session lifecycle in SessionStore.
//  Discovery snapshots register provisional sessions; the first real hook
//  event upgrades them in place (same sessionId key — no duplicates); rescans
//  prune provisionals that fell out of the snapshot; archived sessions are
//  tombstoned so the next rescan doesn't resurrect them.
//
//  Tests use SessionStore.shared (singleton actor) with unique session IDs,
//  same pattern as SessionPhaseTransitionTests. Snapshot events only touch
//  provisional sessions, so leftovers from other tests are unaffected.
//

import XCTest
@testable import Ghostwire

final class SessionDiscoveryStoreTests: XCTestCase {

    private func uniqueSessionId() -> String { UUID().uuidString.lowercased() }

    private func discovered(
        _ sessionId: String,
        cwd: String = "/tmp/gw194-store-tests",
        agent: String = "claude",
        modified: Date = Date()
    ) -> DiscoveredSession {
        DiscoveredSession(
            sessionId: sessionId,
            cwd: cwd,
            agent: agent,
            transcriptPath: cwd + "/" + sessionId + ".jsonl",
            fileModified: modified
        )
    }

    private func hookEvent(
        _ sessionId: String,
        cwd: String = "/tmp/gw194-store-tests",
        event: String = "UserPromptSubmit",
        status: String = "processing",
        pid: Int? = 4242,
        source: String? = "claude"
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: event,
            status: status,
            pid: pid,
            tty: "ttys001",
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            source: source
        )
    }

    // MARK: - Registration

    func testDiscoveredSessionRegistersProvisionalIdle() async {
        let sessionId = uniqueSessionId()
        let modified = Date(timeIntervalSinceNow: -600)

        await SessionStore.shared.process(.sessionsDiscovered([
            discovered(sessionId, agent: "codex", modified: modified)
        ]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNotNil(session, "discovery snapshot must register the session")
        XCTAssertEqual(session?.phase, .idle, "provisional sessions must not claim attention")
        XCTAssertEqual(session?.isProvisional, true)
        XCTAssertEqual(session?.agent, "codex")
        XCTAssertNil(session?.pid, "no pid until a real hook event arrives")
        XCTAssertEqual(session?.lastActivity, modified, "lastActivity tracks the transcript mtime")
    }

    func testDiscoveryDoesNotOverwriteExistingHookSession() async {
        let sessionId = uniqueSessionId()

        await SessionStore.shared.process(.hookReceived(hookEvent(sessionId)))
        await SessionStore.shared.process(.sessionsDiscovered([
            discovered(sessionId, cwd: "/somewhere/else")
        ]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.pid, 4242, "hook-known session must keep its pid")
        XCTAssertEqual(session?.isProvisional, false)
        XCTAssertEqual(session?.cwd, "/tmp/gw194-store-tests", "hook cwd is authoritative")
        XCTAssertEqual(session?.phase, .processing)
    }

    // MARK: - Upgrade in place

    func testHookEventUpgradesProvisionalInPlace() async {
        let sessionId = uniqueSessionId()

        await SessionStore.shared.process(.sessionsDiscovered([
            // Lossy dirname-decoded cwd — the hook event carries the real one
            discovered(sessionId, cwd: "/Users/test/my/app")
        ]))
        await SessionStore.shared.process(.hookReceived(hookEvent(
            sessionId, cwd: "/Users/test/my.app"
        )))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.isProvisional, false, "first hook event upgrades the provisional")
        XCTAssertEqual(session?.pid, 4242)
        XCTAssertEqual(session?.cwd, "/Users/test/my.app", "hook cwd replaces the discovery guess")
        XCTAssertEqual(session?.phase, .processing)

        let all = await SessionStore.shared.allSessions()
        XCTAssertEqual(all.filter { $0.sessionId == sessionId }.count, 1, "no duplicate rows")
    }

    // MARK: - Pruning

    func testSnapshotPrunesProvisionalAbsentFromScan() async {
        let sessionId = uniqueSessionId()

        await SessionStore.shared.process(.sessionsDiscovered([discovered(sessionId)]))
        // Next scan no longer returns it (aged out, deleted, or CLI gone)
        await SessionStore.shared.process(.sessionsDiscovered([]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNil(session, "provisional absent from the latest snapshot must be pruned")
    }

    func testSnapshotDoesNotPruneHookBackedSessions() async {
        let sessionId = uniqueSessionId()

        await SessionStore.shared.process(.hookReceived(hookEvent(sessionId)))
        await SessionStore.shared.process(.sessionsDiscovered([]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNotNil(session, "hook-backed sessions have a real lifecycle — never scan-pruned")
    }

    func testRescanRefreshesProvisionalLastActivity() async {
        let sessionId = uniqueSessionId()
        let first = Date(timeIntervalSinceNow: -3600)
        let second = Date(timeIntervalSinceNow: -60)

        await SessionStore.shared.process(.sessionsDiscovered([discovered(sessionId, modified: first)]))
        await SessionStore.shared.process(.sessionsDiscovered([discovered(sessionId, modified: second)]))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertEqual(session?.lastActivity, second)
    }

    // MARK: - Tombstones

    func testArchivedProvisionalDoesNotResurrect() async {
        let sessionId = uniqueSessionId()
        let snapshot = [discovered(sessionId)]

        await SessionStore.shared.process(.sessionsDiscovered(snapshot))
        await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        // Same transcript still on disk -> next rescan returns it again
        await SessionStore.shared.process(.sessionsDiscovered(snapshot))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNil(session, "archived session must not resurrect on the next rescan")
    }

    func testNewHookEventClearsTombstone() async {
        let sessionId = uniqueSessionId()
        let snapshot = [discovered(sessionId)]

        await SessionStore.shared.process(.sessionsDiscovered(snapshot))
        await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        // The session comes back for real (e.g. claude --resume)
        await SessionStore.shared.process(.hookReceived(hookEvent(sessionId)))

        let session = await SessionStore.shared.session(for: sessionId)
        XCTAssertNotNil(session, "a real hook event must always register, tombstone or not")
        XCTAssertEqual(session?.isProvisional, false)
    }
}
