//
//  GatewayUpstreamTests.swift
//  GhostwireTests
//
//  GW-253: the gateway re-exposes downstream MCP servers under a per-server
//  namespace. Slugs must be underscore-free — Gemini CLI splits the tool FQN
//  on underscores, so an underscore in the server slug breaks its policy parser.
//

import XCTest

@testable import Ghostwire

final class GatewayUpstreamTests: XCTestCase {
    func testSlugifyStripsNonAlphanumericAndUnderscores() {
        XCTAssertEqual(GatewaySlug.slugify("Linear"), "linear")
        XCTAssertEqual(GatewaySlug.slugify("Google Sheets"), "googlesheets")
        XCTAssertEqual(GatewaySlug.slugify("my_server"), "myserver")  // no underscores survive
        XCTAssertEqual(GatewaySlug.slugify("!!!"), "server")  // fallback
    }
}
