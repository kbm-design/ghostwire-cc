import XCTest

@testable import Ghostwire

final class LoginShellPATHResolverTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeExecutable(named name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testResolvesCommandOnGivenPATH() throws {
        let expected = try makeExecutable(named: "fakecmd")
        let resolved = LoginShellPATHResolver.resolve(
            command: "fakecmd",
            searchPath: "/nonexistent:\(tempDir.path)"
        )
        XCTAssertEqual(resolved, expected)
    }

    func testAbsolutePathPassesThroughWhenExecutable() throws {
        let expected = try makeExecutable(named: "absolute")
        XCTAssertEqual(LoginShellPATHResolver.resolve(command: expected, searchPath: ""), expected)
    }

    func testMissingCommandReturnsNil() {
        XCTAssertNil(LoginShellPATHResolver.resolve(command: "definitely-not-real-xyz", searchPath: tempDir.path))
    }

    func testNonExecutableFileIsSkipped() throws {
        let url = tempDir.appendingPathComponent("notexec")
        try "data".write(to: url, atomically: true, encoding: .utf8)  // 0644
        XCTAssertNil(LoginShellPATHResolver.resolve(command: "notexec", searchPath: tempDir.path))
    }

    func testLoginShellPATHContainsStandardBins() async {
        // Real shell exec — sanity that the mechanism works end-to-end.
        let path = await LoginShellPATHResolver.shared.loginShellPATH()
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}
