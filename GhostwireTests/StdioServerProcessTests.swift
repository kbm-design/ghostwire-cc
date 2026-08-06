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
}
