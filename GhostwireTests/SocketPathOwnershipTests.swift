//
//  SocketPathOwnershipTests.swift
//  GhostwireTests
//
//  GW-414: `HookSocketServer.stop()` used to `unlink()` the socket path
//  unconditionally, so it was destructive from any process that had merely
//  loaded the class. `xcodebuild test` boots the app as its XCTest host:
//  `startMonitoring()` correctly no-ops under XCTest and never binds, but
//  teardown still ran `applicationWillTerminate` -> `stopMonitoring()` ->
//  `stop()`, deleting the *live* Ghostwire instance's socket.
//
//  The live app kept its bound fd, so it looked healthy, while every new hook
//  connection failed — and every gated tool call then fail-closed denied. That
//  is GW-413's "socket: none anywhere on disk, Ghostwire running". Nothing
//  logged it, which is why it read as an approval bug rather than a test-host
//  side effect.
//
//  These tests run against a temp path on purpose. Exercising the real
//  `/tmp/com.ghostwire.notch.sock` would reproduce the bug rather than test it.
//

import XCTest
@testable import Ghostwire

final class SocketPathOwnershipTests: XCTestCase {

    private var tempPath: String!

    override func setUpWithError() throws {
        tempPath = NSTemporaryDirectory()
            .appending("gw414-\(UUID().uuidString).sock")
        FileManager.default.createFile(atPath: tempPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath),
                      "fixture failed to create the stand-in socket path")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    /// The regression. A process that never bound must leave the path alone.
    func testNonOwnerDoesNotRemoveTheSocketPath() {
        HookSocketServer.unlinkSocketPathIfOwned(tempPath, owned: false)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempPath),
            "stop() removed a socket path this process never bound — a test host would delete the live app's socket and every gated tool call would then fail closed"
        )
    }

    /// The owner still cleans up after itself; the fix must not leak stale
    /// socket files, or the next launch binds over a path it did not create.
    func testOwnerRemovesTheSocketPath() {
        HookSocketServer.unlinkSocketPathIfOwned(tempPath, owned: true)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempPath),
            "the binding process must remove its own socket path on shutdown"
        )
    }

    /// Repeated teardown is normal (explicit quit, then app termination).
    func testUnlinkingTwiceIsHarmless() {
        HookSocketServer.unlinkSocketPathIfOwned(tempPath, owned: true)
        HookSocketServer.unlinkSocketPathIfOwned(tempPath, owned: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))
    }

    /// Guards the live path specifically: whatever else changes, a non-owner
    /// must never be able to remove the socket every agent on the machine
    /// depends on.
    func testLiveSocketPathIsNeverRemovedByANonOwner() {
        let livePathExistedBefore = FileManager.default
            .fileExists(atPath: HookSocketServer.socketPath)

        HookSocketServer.unlinkSocketPathIfOwned(HookSocketServer.socketPath, owned: false)

        XCTAssertEqual(
            FileManager.default.fileExists(atPath: HookSocketServer.socketPath),
            livePathExistedBefore,
            "the real hook socket changed state during a unit test — this is the exact failure GW-414 describes"
        )
    }
}
