//
//  HookResponseExitPlanModeTests.swift
//  GhostwireTests
//
//  Claude's ExitPlanMode gate silently ignores a bare {"behavior":"allow"}.
//  The socket response needs to be able to carry updatedInput through Python.
//

import XCTest
@testable import Ghostwire

final class HookResponseExitPlanModeTests: XCTestCase {

    func testHookResponseCanEncodeUpdatedInput() throws {
        let response = HookResponse(
            decision: "allow",
            reason: nil,
            updatedInput: ["plan": AnyCodable("Ship the remediation")]
        )

        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let updatedInput = object?["updatedInput"] as? [String: Any]

        XCTAssertEqual(object?["decision"] as? String, "allow")
        XCTAssertEqual(updatedInput?["plan"] as? String, "Ship the remediation")
    }
}
