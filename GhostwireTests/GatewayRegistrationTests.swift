//
//  GatewayRegistrationTests.swift
//  GhostwireTests
//
//  GW-253 Phase 2: the copyable command that registers the localhost gateway
//  with a host agent over HTTP, carrying the bearer token.
//

import XCTest

@testable import Ghostwire

final class GatewayRegistrationTests: XCTestCase {
    func testClaudeCodeHTTPRegisterCommand() {
        let cmd = GatewayRegistration.claudeCommand(
            endpointURL: "http://127.0.0.1:51762/mcp", token: "abc123")
        XCTAssertEqual(
            cmd,
            "claude mcp add --transport http ghostwire-gateway "
                + "http://127.0.0.1:51762/mcp --header \"Authorization: Bearer abc123\"")
    }
}
