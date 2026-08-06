//
//  MCPOAuthLoopbackTests.swift
//  GhostwireTests
//
//  GW-219: Unit + integration tests for the loopback OAuth redirect
//  machinery introduced in MCPOAuthCoordinator. Tests cover:
//    - Determinism and range of loopbackPort(for:)
//    - redirectURI(for:) shape
//    - redirectURI(fromAuthorizeURL:) extraction
//    - OAuthLoopbackListener integration (real TCP, URLSession callback)
//

import XCTest
@testable import Ghostwire

final class MCPOAuthLoopbackTests: XCTestCase {

    // MARK: - loopbackPort

    func testLoopbackPortIsDeterministic() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let first = MCPOAuthCoordinator.loopbackPort(for: id)
        let second = MCPOAuthCoordinator.loopbackPort(for: id)
        XCTAssertEqual(first, second, "loopbackPort must be stable across calls for the same UUID")
    }

    func testLoopbackPortInRange() {
        let id = UUID()
        let port = MCPOAuthCoordinator.loopbackPort(for: id)
        XCTAssertGreaterThanOrEqual(port, 10000, "port should be >= 10000")
        XCTAssertLessThan(port, 55000, "port should be < 55000")
    }

    func testLoopbackPortDiffersAcrossUUIDs() {
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let portA = MCPOAuthCoordinator.loopbackPort(for: a)
        let portB = MCPOAuthCoordinator.loopbackPort(for: b)
        XCTAssertNotEqual(portA, portB, "different UUIDs should (almost certainly) produce different ports")
    }

    // MARK: - redirectURI(for:)

    func testRedirectURIShape() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let uri = MCPOAuthCoordinator.redirectURI(for: id)
        XCTAssertEqual(uri.host, "127.0.0.1")
        XCTAssertEqual(uri.path, "/callback")
        XCTAssertEqual(uri.scheme, "http")
        XCTAssertEqual(uri.port, Int(MCPOAuthCoordinator.loopbackPort(for: id)))
    }

    // MARK: - redirectURI(fromAuthorizeURL:)

    func testRedirectURIFromAuthorizeURLExtraction() {
        // Encode a redirect_uri param inside a typical authorize URL.
        let redirectParam = "http://127.0.0.1:12345/callback"
        let encoded = redirectParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let authorizeURL = URL(string: "https://as.example/authorize?client_id=x&redirect_uri=\(encoded)&state=s")!

        let extracted = MCPOAuthCoordinator.redirectURI(fromAuthorizeURL: authorizeURL)
        XCTAssertNotNil(extracted, "should extract redirect_uri from authorize URL")
        XCTAssertEqual(extracted?.absoluteString, redirectParam)
    }

    func testRedirectURIFromAuthorizeURLMissingParam() {
        let authorizeURL = URL(string: "https://as.example/authorize?client_id=x&state=s")!
        XCTAssertNil(MCPOAuthCoordinator.redirectURI(fromAuthorizeURL: authorizeURL))
    }

    // MARK: - OAuthLoopbackListener integration

    func testLoopbackListenerReceivesCallback() async throws {
        // Use a fixed UUID so the port is deterministic.
        let serverID = UUID(uuidString: "CAFEBABE-CAFE-BABE-CAFE-BABECAFEBABE")!
        let port = MCPOAuthCoordinator.loopbackPort(for: serverID)
        let listener = try OAuthLoopbackListener(
            port: port, expectedPath: "/callback", expectedState: "xyz")

        async let callbackURL = listener.waitForCallback(timeout: 10)

        // Small yield to let the listener start before we send the request.
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        let requestURL = URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!
        let (_, response) = try await URLSession.shared.data(from: requestURL)
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 200)

        let result = try await callbackURL
        listener.stop()

        XCTAssertNotNil(result.query, "callback URL should have a query string")
        let components = URLComponents(url: result, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let code = items.first { $0.name == "code" }?.value
        let state = items.first { $0.name == "state" }?.value
        XCTAssertEqual(code, "abc")
        XCTAssertEqual(state, "xyz")
    }

    func testLoopbackListenerIgnoresFaviconAndWaits() async throws {
        let serverID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
        let port = MCPOAuthCoordinator.loopbackPort(for: serverID)
        let listener = try OAuthLoopbackListener(
            port: port, expectedPath: "/callback", expectedState: "s")

        async let callbackURL = listener.waitForCallback(timeout: 10)

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        // First send a non-matching request (favicon); listener should 404 and keep going.
        let faviconURL = URL(string: "http://127.0.0.1:\(port)/favicon.ico")!
        let (_, faviconResponse) = try await URLSession.shared.data(from: faviconURL)
        XCTAssertEqual((faviconResponse as? HTTPURLResponse)?.statusCode, 404)

        // Now send the real callback.
        let realURL = URL(string: "http://127.0.0.1:\(port)/callback?code=xyz&state=s")!
        _ = try await URLSession.shared.data(from: realURL)

        let result = try await callbackURL
        listener.stop()

        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "xyz")
    }

    func testLoopbackListenerRejectsWrongStateAndKeepsWaiting() async throws {
        let serverID = UUID(uuidString: "FACEFEED-FACE-FEED-FACE-FEEDFACEFEED")!
        let port = MCPOAuthCoordinator.loopbackPort(for: serverID)
        let listener = try OAuthLoopbackListener(
            port: port, expectedPath: "/callback", expectedState: "expected-state")

        async let callbackURL = listener.waitForCallback(timeout: 10)

        try await Task.sleep(nanoseconds: 100_000_000)

        let wrongURL = URL(string: "http://127.0.0.1:\(port)/callback?code=bad&state=wrong")!
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrongURL)
        XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 400)

        let realURL = URL(
            string: "http://127.0.0.1:\(port)/callback?code=good&state=expected-state")!
        _ = try await URLSession.shared.data(from: realURL)

        let result = try await callbackURL
        listener.stop()

        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "good")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "expected-state")
    }
}
