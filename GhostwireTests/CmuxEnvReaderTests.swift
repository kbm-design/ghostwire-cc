//
//  CmuxEnvReaderTests.swift
//  GhostwireTests
//
//  GW-204: cmux identity now comes from the pane's inherited ENV
//  (CMUX_SURFACE_ID / CMUX_WORKSPACE_ID), read via sysctl KERN_PROCARGS2, not
//  from screen-scraping (which picked the wrong pane with parallel worktrees of
//  one repo). The sysctl call can't be unit-tested against arbitrary PIDs, so
//  these tests exercise the two pure seams it feeds:
//    1. KERN_PROCARGS2 buffer -> env dict (`parseProcArgs`)
//    2. env dict -> cmux target refs (`cmuxRefs` / `cmuxTarget`)
//
//  Verified 2026-06-04: the env value equals `cmux --json identify`'s
//  caller.surface_id, so an env read agrees with a hook ref on the same surface.
//

import XCTest
@testable import Ghostwire

final class CmuxEnvReaderTests: XCTestCase {

    // MARK: - Buffer builder (mirrors the Darwin KERN_PROCARGS2 layout)

    /// Build a KERN_PROCARGS2-shaped buffer: int32 argc, exec_path (NUL),
    /// optional NUL padding, argc argv strings, then env strings.
    private func makeProcArgs(
        execPath: String = "/usr/bin/some-agent",
        padding: Int = 0,
        argv: [String],
        env: [String]
    ) -> [UInt8] {
        var buffer: [UInt8] = []

        var argc = Int32(argv.count)
        withUnsafeBytes(of: &argc) { buffer.append(contentsOf: $0) }

        func appendCString(_ s: String) {
            buffer.append(contentsOf: Array(s.utf8))
            buffer.append(0)
        }

        appendCString(execPath)
        buffer.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for a in argv { appendCString(a) }
        for e in env { appendCString(e) }

        return buffer
    }

    // MARK: - parseProcArgs

    func testParsesEnvBlock() {
        let buffer = makeProcArgs(
            argv: ["node", "/path/cmux"],
            env: ["PATH=/usr/bin", "CMUX_SURFACE_ID=surface:35", "CMUX_WORKSPACE_ID=workspace:17"]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertEqual(env["CMUX_SURFACE_ID"], "surface:35")
        XCTAssertEqual(env["CMUX_WORKSPACE_ID"], "workspace:17")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testParsesWithNulPaddingAfterExecPath() {
        // Darwin pads exec_path with NULs up to a pointer boundary before argv[0].
        let buffer = makeProcArgs(
            padding: 6,
            argv: ["claude"],
            env: ["CMUX_SURFACE_ID=surface:1", "CMUX_WORKSPACE_ID=workspace:2"]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertEqual(env["CMUX_SURFACE_ID"], "surface:1")
        XCTAssertEqual(env["CMUX_WORKSPACE_ID"], "workspace:2")
    }

    func testValueWithEqualsSignIsPreserved() {
        // splitEnvEntry splits on the FIRST '=', so '=' inside the value survives.
        let buffer = makeProcArgs(
            argv: ["sh"],
            env: ["FOO=a=b=c", "CMUX_SURFACE_ID=surface:9"]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertEqual(env["FOO"], "a=b=c")
        XCTAssertEqual(env["CMUX_SURFACE_ID"], "surface:9")
    }

    func testEntriesWithoutEqualsAreIgnored() {
        let buffer = makeProcArgs(
            argv: ["sh"],
            env: ["JUSTAWORD", "CMUX_SURFACE_ID=surface:5"]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertNil(env["JUSTAWORD"])
        XCTAssertEqual(env["CMUX_SURFACE_ID"], "surface:5")
    }

    func testEmptyValueIsKept() {
        let buffer = makeProcArgs(argv: ["sh"], env: ["EMPTY="])
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertEqual(env["EMPTY"], "")
    }

    func testTooSmallBufferYieldsEmpty() {
        XCTAssertTrue(CmuxEnvReader.parseProcArgs([0x01, 0x02]).isEmpty)
    }

    func testNoEnvVarsYieldsEmpty() {
        let buffer = makeProcArgs(argv: ["sh", "-c", "true"], env: [])
        XCTAssertTrue(CmuxEnvReader.parseProcArgs(buffer).isEmpty)
    }

    func testArgvIsNotMistakenForEnv() {
        // An argv token that looks like KEY=VALUE must not leak into the env dict.
        let buffer = makeProcArgs(
            argv: ["sh", "DECOY=fromargv"],
            env: ["CMUX_SURFACE_ID=surface:3"]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        XCTAssertNil(env["DECOY"])
        XCTAssertEqual(env["CMUX_SURFACE_ID"], "surface:3")
    }

    // MARK: - cmuxRefs / cmuxTarget

    func testBothRefsPresentResolves() {
        let env = ["CMUX_WORKSPACE_ID": "workspace:17", "CMUX_SURFACE_ID": "surface:35"]
        let refs = CmuxEnvReader.cmuxRefs(fromEnv: env)
        XCTAssertEqual(refs?.workspace, "workspace:17")
        XCTAssertEqual(refs?.surface, "surface:35")

        let target = CmuxEnvReader.cmuxTarget(fromEnv: env)
        // cmux refs are only non-nil for cmux-typed targets
        XCTAssertEqual(target?.cmuxWorkspaceRef, "workspace:17")
        XCTAssertEqual(target?.cmuxSurfaceRef, "surface:35")
    }

    func testMissingSurfaceIsNil() {
        // half-set env is not a usable target (mirrors the hook-ref policy)
        let env = ["CMUX_WORKSPACE_ID": "workspace:17"]
        XCTAssertNil(CmuxEnvReader.cmuxRefs(fromEnv: env))
        XCTAssertNil(CmuxEnvReader.cmuxTarget(fromEnv: env))
    }

    func testMissingWorkspaceIsNil() {
        let env = ["CMUX_SURFACE_ID": "surface:35"]
        XCTAssertNil(CmuxEnvReader.cmuxRefs(fromEnv: env))
    }

    func testEmptyRefValuesAreNil() {
        let env = ["CMUX_WORKSPACE_ID": "", "CMUX_SURFACE_ID": "surface:35"]
        XCTAssertNil(CmuxEnvReader.cmuxRefs(fromEnv: env))
    }

    func testNoCmuxVarsIsNil() {
        // plain terminal / tmux-only env: no cmux target (tiered support stays graceful)
        let env = ["PATH": "/usr/bin", "TERM": "xterm-256color"]
        XCTAssertNil(CmuxEnvReader.cmuxTarget(fromEnv: env))
    }

    // MARK: - end-to-end (buffer -> target)

    func testBufferToTargetEndToEnd() {
        let buffer = makeProcArgs(
            padding: 3,
            argv: ["claude", "--resume"],
            env: [
                "TERM=xterm-256color",
                "CMUX_WORKSPACE_ID=workspace:8",
                "CMUX_SURFACE_ID=surface:42",
            ]
        )
        let env = CmuxEnvReader.parseProcArgs(buffer)
        let target = CmuxEnvReader.cmuxTarget(fromEnv: env)
        XCTAssertEqual(target?.cmuxWorkspaceRef, "workspace:8")
        XCTAssertEqual(target?.cmuxSurfaceRef, "surface:42")
    }
}
