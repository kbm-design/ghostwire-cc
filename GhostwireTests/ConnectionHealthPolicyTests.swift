import XCTest

@testable import Ghostwire

final class ConnectionHealthPolicyTests: XCTestCase {
    func testFirstFailureRetriesInPlace() {
        var policy = ConnectionHealthPolicy()
        XCTAssertEqual(policy.recordFailure(), .retry)
    }

    func testSecondConsecutiveFailureTearsDown() {
        var policy = ConnectionHealthPolicy()
        _ = policy.recordFailure()
        XCTAssertEqual(policy.recordFailure(), .teardownAndReconnect)
    }

    func testSuccessResetsTheCounter() {
        var policy = ConnectionHealthPolicy()
        _ = policy.recordFailure()
        policy.recordSuccess()
        XCTAssertEqual(policy.recordFailure(), .retry)
    }

    func testTeardownDecisionAlsoResets() {
        var policy = ConnectionHealthPolicy()
        _ = policy.recordFailure()
        _ = policy.recordFailure()  // -> teardown, resets
        XCTAssertEqual(policy.recordFailure(), .retry)
    }

    func testWakeAlwaysRevalidates() {
        let policy = ConnectionHealthPolicy()
        XCTAssertEqual(policy.actionOnWake(), .revalidate)
    }
}
