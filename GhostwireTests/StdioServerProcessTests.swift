import XCTest

@testable import Ghostwire

final class StdioServerProcessTests: XCTestCase {
    func testStartSpawnsAndTerminateStops() throws {
        let process = StdioServerProcess()
        let expectation = expectation(description: "terminated")
        process.onTermination = { _ in expectation.fulfill() }
        try process.start(executablePath: "/bin/cat", arguments: [], environment: [:])
        XCTAssertTrue(process.isRunning)
        process.terminate()
        wait(for: [expectation], timeout: 5)
        XCTAssertFalse(process.isRunning)
    }

    func testStartWithMissingExecutableThrows() {
        let process = StdioServerProcess()
        XCTAssertThrowsError(
            try process.start(executablePath: "/nonexistent/bin/xyz", arguments: [], environment: [:])
        )
    }

    func testStderrTailIsCaptured() throws {
        let process = StdioServerProcess()
        try process.start(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo boom >&2; sleep 30"],
            environment: [:]
        )
        // stderr is read asynchronously; poll briefly
        let deadline = Date().addingTimeInterval(3)
        while process.stderrTail.isEmpty && Date() < deadline { usleep(50_000) }
        XCTAssertTrue(process.stderrTail.contains("boom"))
        process.terminate()
    }

    func testStderrTailRedactsInjectedEnvironmentSecrets() throws {
        let process = StdioServerProcess()
        try process.start(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo $GHOSTWIRE_TEST_SECRET >&2; sleep 30"],
            environment: ["GHOSTWIRE_TEST_SECRET": "super-secret-token"]
        )
        let deadline = Date().addingTimeInterval(3)
        while process.stderrTail.isEmpty && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(process.stderrTail.contains("super-secret-token"))
        XCTAssertTrue(process.stderrTail.contains("[redacted]"))
        process.terminate()
    }
}
