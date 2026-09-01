//
//  CredentialShapeDetectorTests.swift
//  GhostwireTests
//
//  GW-166: the detection policy, as a table. Every row is a claim about what
//  Ghostwire will and won't lock behind Touch ID, so adding a heuristic means
//  adding rows here — including to `negatives`, which is the half that keeps the
//  feature usable. The detector is pure, so none of this touches the pasteboard,
//  the Keychain, the defaults domain, or the disk.
//
//  Token values below are structurally real but cryptographically junk —
//  keyboard-mashed bodies behind real prefixes. Nothing here is a live secret.
//

import XCTest
@testable import Ghostwire

final class CredentialShapeDetectorTests: XCTestCase {

    private struct Case {
        let text: String
        let expected: CredentialShape?
        let why: String
        let line: UInt

        init(_ text: String, _ expected: CredentialShape?, _ why: String, line: UInt = #line) {
            self.text = text
            self.expected = expected
            self.why = why
            self.line = line
        }
    }

    private func check(_ cases: [Case]) {
        for c in cases {
            let actual = CredentialShapeDetector.shape(of: c.text)
            XCTAssertEqual(
                actual, c.expected,
                "\(c.why) — got \(actual.map(\.rawValue) ?? "nil") for \(preview(c.text))",
                line: c.line
            )
        }
    }

    private func preview(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 48 ? "\"\(flat)\"" : "\"\(flat.prefix(45))…\""
    }

    // MARK: - Positives

    func testKnownTokenPrefixes() {
        check([
            Case("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8", .tokenPrefix, "GitHub classic PAT"),
            Case("github_pat_11ABCDEFG0aBcDeFgHiJkL_mNoPqRsTuVwXyZ0123456789", .tokenPrefix, "GitHub fine-grained PAT"),
            Case("glpat-aB3dE7gH9jK1mN4pQ6rS", .tokenPrefix, "GitLab PAT"),
            Case("sk-ant-api03-Zx9yW8vU7tS6rQ5pO4nM3lK2jI1h", .tokenPrefix, "Anthropic key"),
            Case("sk-proj-aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0u", .tokenPrefix, "OpenAI project key"),
            Case("xoxb-9876543210-1234567890-aBcDeFgHiJkLmNoPqRsT", .tokenPrefix, "Slack bot token"),
            Case("AKIAQ4NZ7XKPLMWD3TYU", .tokenPrefix, "AWS access key id"),
            Case("AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q", .tokenPrefix, "Google API key"),
            Case("npm_aB1cD2eF3gH4iJ5kL6mN7oP8qR9sT0uV1w", .tokenPrefix, "npm token"),
            Case("lin_api_aB1cD2eF3gH4iJ5kL6mN7oP8", .tokenPrefix, "Linear API key"),
        ])
    }

    func testPrefixNeedsEnoughBodyToCount() {
        // The prefix alone, or a word that merely starts with one, is not a token.
        check([
            Case("sk-", nil, "bare prefix"),
            Case("sk-test", nil, "too short to be a key"),
            Case("ghp_short", nil, "GitHub prefix without a token body"),
            Case("AKIA", nil, "bare AWS prefix"),
        ])
    }

    func testJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ"
            + ".dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        check([
            Case(jwt, .jwt, "three base64url segments with a JSON header"),
            Case("eyJhbGciOiJIUzI1NiJ9.short", nil, "two segments is not a JWT"),
        ])
    }

    func testPrivateKeyBlock() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdz
        c2gtcn NhAAAAAwEAAQAAAYEAwJ7mQ3Dk1vZpX2LqYs0aBcDeFgHiJkLmNoPqRs
        -----END OPENSSH PRIVATE KEY-----
        """
        check([
            Case(pem, .privateKey, "PEM block, multi-line"),
            Case("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----", .privateKey, "RSA PEM"),
            Case("-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----", nil, "a public cert is not a key"),
        ])
    }

    func testURLCredentials() {
        check([
            Case("postgres://admin:s3cr3tpassw0rd@db.internal:5432/app", .urlCredential, "DSN with a password"),
            Case("https://user:ghp_A1b2C3d4E5f6G7h8@github.com/org/repo.git", .urlCredential, "token in a git URL"),
            Case("https://example.com/path?q=1", nil, "ordinary URL"),
            Case("ssh://git@github.com/org/repo.git", nil, "username with no password"),
        ])
    }

    func testSecretAssignments() {
        check([
            Case("API_KEY=aB3dE7gH9jK1mN4p", .assignment, "shell-style env assignment"),
            Case("export DATABASE_PASSWORD=hunter2hunter2", .assignment, "exported env var"),
            Case("\"client_secret\": \"aB3dE7gH9jK1mN4p\"", .assignment, "JSON config value"),
            Case("some_token: aB3dE7gH9jK1mN4p", .assignment, "YAML-style value"),
            Case(
                "# .env\nAPP_NAME=ghostwire\nSTRIPE_SECRET=aB3dE7gH9jK1mN4pQ6r\nDEBUG=true",
                .assignment,
                "a secret on ANY line flags the whole clip"
            ),
        ])
    }

    func testAssignmentsThatAreNotSecrets() {
        check([
            Case("API_KEY=<your-key-here>", nil, "angle-bracket placeholder"),
            Case("API_KEY=${STRIPE_KEY}", nil, "shell interpolation"),
            Case("password: xxxxxxxxxx", nil, "redacted with a repeated character"),
            Case("API_KEY=your_key_here", nil, "template placeholder"),
            Case("let token = refreshToken", nil, "unquoted all-letter identifier is code"),
            Case("password: short", nil, "value below the length floor"),
            Case("timeout=30", nil, "not a secret-shaped name"),
            Case("name: ghostwire-notch", nil, "ordinary config key"),
        ])
    }

    func testHexBlobs() {
        check([
            Case(String(repeating: "a1b2c3d4", count: 4), .hexBlob, "32 hex chars"),
            Case(String(repeating: "9f", count: 32), .hexBlob, "64 hex chars"),
            Case("deadbeef", nil, "too short to be a key"),
        ])
    }

    /// The carve-out that keeps the feature usable for developers.
    func testGitSHAIsNotFlagged() {
        check([
            Case("6f6b81a2c3d4e5f60718293a4b5c6d7e8f901234", nil, "40-char hex is a git SHA-1"),
            Case("6f6b81a", nil, "short SHA"),
        ])
    }

    func testRandomTokens() {
        check([
            Case("wJalrXUtnFEMIbPxRfiCYzEXAMPLEKEY7aQ", .randomToken, "AWS-secret-shaped base64 blob"),
            Case("Zx9yW8vU7tS6rQ5pO4nM3lK2jI1hG0fE9dC8bA7", .randomToken, "mixed-case high-entropy blob"),
        ])
    }

    /// Everything a developer copies all day that must NOT demand Touch ID.
    func testEverydayCopiesAreNotFlagged() {
        check([
            Case("Hello, world!", nil, "prose"),
            Case("The quick brown fox jumps over the lazy dog", nil, "a sentence"),
            Case("/Users/keelan/Desktop/Coding/Notch/ghostwire-notch", nil, "absolute path"),
            Case("~/Library/Developer/Xcode/DerivedData", nil, "home-relative path"),
            Case("https://linear.app/ghostwire/issue/GW-166/clipboard-history", nil, "long URL"),
            Case("3F2504E0-4F89-11D3-9A0C-0305E82C3301", nil, "UUID"),
            Case("keelan.miskell@gmail.com", nil, "email address"),
            Case("UnifiedShelfViewModel2", nil, "mixed-case identifier with a digit"),
            Case("NSApplicationDidFinishLaunchingNotification", nil, "long symbol, no digits"),
            Case("screenshot20260825at1432", nil, "lowercase filename-ish string"),
            Case("1.2.3-beta.4", nil, "semantic version"),
            Case("+353871234567", nil, "phone number"),
            Case("xcodebuild -scheme Ghostwire -destination 'platform=macOS'", nil, "a shell command"),
            Case("", nil, "empty"),
            Case("   \n\t ", nil, "whitespace only"),
        ])
    }

    // MARK: - Boundaries

    func testOversizeClipIsNotScanned() {
        // A document isn't a credential — and this keeps the entropy scan bounded.
        let huge = String(repeating: "a1b2c3d4", count: CredentialShapeDetector.maxScanBytes)
        XCTAssertNil(CredentialShapeDetector.shape(of: huge))
    }

    func testOversizeTokenIsNotFlagged() {
        let tooLong = "ghp_" + String(repeating: "aB1c", count: CredentialShapeDetector.maxTokenLength)
        XCTAssertNil(CredentialShapeDetector.shape(of: tooLong))
    }

    func testDetectionIgnoresSurroundingWhitespace() {
        XCTAssertEqual(
            CredentialShapeDetector.shape(of: "  ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8\n"),
            .tokenPrefix
        )
    }

    // MARK: - Component rules

    func testEntropyOrdering() {
        // Sanity-check the measure the fuzzy rule leans on: repetition scores low,
        // varied text scores high.
        let flat = CredentialShapeDetector.shannonEntropy(String(repeating: "a", count: 32))
        let varied = CredentialShapeDetector.shannonEntropy("Zx9yW8vU7tS6rQ5pO4nM3lK2jI1h")
        XCTAssertEqual(flat, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(varied, CredentialShapeDetector.minRandomTokenEntropy)
    }

    func testEveryShapeHasALabel() {
        for shape in CredentialShape.allCases {
            XCTAssertFalse(shape.label.isEmpty, "\(shape.rawValue) needs a label for the masked card")
        }
    }

    func testIsCredentialShapedMatchesShape() {
        XCTAssertTrue(CredentialShapeDetector.isCredentialShaped("ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"))
        XCTAssertFalse(CredentialShapeDetector.isCredentialShaped("Hello, world!"))
    }
}
