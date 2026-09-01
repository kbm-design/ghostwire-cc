//
//  CredentialShapeDetector.swift
//  Ghostwire
//
//  GW-166: decide whether a copied string *looks like* a credential, so the
//  capture path can seal it instead of writing it to history in plaintext.
//
//  SHAPE ONLY. This never looks at the source app, never asks the network, and
//  never keeps state — a pure `String -> CredentialShape?` so the whole policy
//  is a table-driven unit test (CredentialShapeDetectorTests). Source-app lists
//  (the NotchPad/Supaste approach: "came from 1Password") are deliberately out:
//  password managers already mark their copies concealed and are skipped
//  upstream; the gap this closes is a token pasted out of a terminal, a .env,
//  or a web dashboard, where the app tells us nothing.
//
//  PRECISION OVER RECALL, on purpose. A false positive costs a Touch ID prompt
//  plus one "Not sensitive" click; a false negative writes a live credential to
//  ~/.ghostwire/clipboard-history.json. But an over-eager detector that fires on
//  every git SHA is one users switch off entirely, which is a 100% false
//  negative rate. So the fuzzy rules (`randomToken`) are tuned tight and the
//  high-frequency developer copies are carved out explicitly:
//    • 40-char hex          — a git SHA-1, not a secret (see `hexBlob`)
//    • UUIDs                — ids, not secrets
//    • URLs / paths / email — structure, not entropy
//  Recall is bought back by the prefix table, which is exact.
//

import Foundation

/// The shape rule that matched. The raw value is what's persisted on the entry
/// (forward-compat: an unknown rawValue still reads back as "sensitive", it just
/// loses the label), and `label` is what the masked card shows.
enum CredentialShape: String, Codable, Sendable, CaseIterable {
    /// `-----BEGIN … PRIVATE KEY-----` block (multi-line, the one exception to
    /// the single-token rules).
    case privateKey
    /// `scheme://user:password@host` — the credential is inside a URL.
    case urlCredential
    /// A `header.payload.signature` JSON Web Token.
    case jwt
    /// A known issuer prefix (`ghp_`, `sk-ant-`, `AKIA…`) — exact, high-confidence.
    case tokenPrefix
    /// A `SECRET_NAME=value` / `"api_key": "value"` line, at any line of the clip.
    case assignment
    /// A long run of hex that isn't a git SHA.
    case hexBlob
    /// Mixed-case high-entropy blob with no recognisable prefix.
    case randomToken

    /// Short human label for the masked card / row. Deliberately vague about
    /// the vendor — we're describing a shape, not making a claim.
    var label: String {
        switch self {
        case .privateKey: return "Private key"
        case .urlCredential: return "URL with password"
        case .jwt: return "Token (JWT)"
        case .tokenPrefix: return "API token"
        case .assignment: return "Secret value"
        case .hexBlob: return "Secret (hex)"
        case .randomToken: return "Secret (random)"
        }
    }
}

enum CredentialShapeDetector {

    /// The shape `text` matches, or nil when nothing does. Pure; no I/O, no state.
    ///
    /// Rules run in confidence order — the first match wins, so the label a card
    /// shows is always the strongest signal found, not the last one checked.
    static func shape(of text: String) -> CredentialShape? {
        // Whole-clip guards. `maxScanBytes` is well above any real credential
        // (an RSA-4096 PEM is ~3.2 KB) and keeps the entropy scan bounded even
        // though capture already caps at 100 KB.
        guard text.utf8.count <= maxScanBytes else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. PEM private-key block — multi-line by nature, checked before the
        //    single-token rules can reject it for containing whitespace.
        if trimmed.contains("-----BEGIN"), trimmed.contains("PRIVATE KEY") {
            return .privateKey
        }

        // 2. Credentials embedded in a URL (`postgres://user:pw@host/db`).
        if containsURLCredential(trimmed) { return .urlCredential }

        // 3. `NAME=value` / `"name": "value"` on ANY line — this is what copying
        //    a chunk of a .env or a config block looks like.
        if containsSecretAssignment(trimmed) { return .assignment }

        // Everything below is a bare token: one word, no whitespace at all.
        guard isSingleToken(trimmed), trimmed.count <= maxTokenLength else { return nil }

        // 4. JWT — `eyJ` is base64 for `{"`, so this is a strong exact signal.
        if isJWT(trimmed) { return .jwt }

        // 5. Known issuer prefixes. Exact table, so no entropy guard needed.
        if matchesTokenPrefix(trimmed) { return .tokenPrefix }

        // Benign shapes that would otherwise trip the fuzzy rules below.
        guard !isBenignToken(trimmed) else { return nil }

        // 6. Long hex that isn't a git SHA-1.
        if isHexBlob(trimmed) { return .hexBlob }

        // 7. Mixed-case, high-entropy, no recognisable structure.
        if isRandomToken(trimmed) { return .randomToken }

        return nil
    }

    /// True when `text` should be sealed. Thin wrapper for call sites that don't
    /// need the label.
    static func isCredentialShaped(_ text: String) -> Bool { shape(of: text) != nil }

    // MARK: - Tuning constants (single place to argue with the thresholds)

    /// Beyond this a clip is a document, not a credential.
    static let maxScanBytes = 64 * 1024
    /// No real bare token is longer than this; above it we're looking at data.
    static let maxTokenLength = 512
    /// `randomToken` floor. High on purpose — below ~28 chars, mixed-case
    /// identifiers (`UnifiedShelfViewModel2`) score the same as real tokens.
    static let minRandomTokenLength = 28
    /// Shannon entropy (bits/char) a `randomToken` must clear.
    static let minRandomTokenEntropy = 3.9
    /// `hexBlob` floor — 32 hex chars is 128 bits.
    static let minHexBlobLength = 32
    /// A git SHA-1. Developers copy these constantly and they are not secrets.
    static let gitSHALength = 40
    /// Shortest value an assignment's right-hand side can have to count.
    static let minAssignmentValueLength = 8

    // MARK: - Prefix table

    /// (prefix, minimum total length, description). Case-sensitive — every one
    /// of these is emitted with fixed case by its issuer. `minLength` stops a
    /// bare `sk-` or the word `secret_` from matching.
    struct TokenPrefix {
        let prefix: String
        let minLength: Int
        let issuer: String
    }

    static let tokenPrefixes: [TokenPrefix] = [
        // GitHub (all fine-grained + classic forms)
        TokenPrefix(prefix: "ghp_", minLength: 20, issuer: "GitHub"),
        TokenPrefix(prefix: "gho_", minLength: 20, issuer: "GitHub"),
        TokenPrefix(prefix: "ghu_", minLength: 20, issuer: "GitHub"),
        TokenPrefix(prefix: "ghs_", minLength: 20, issuer: "GitHub"),
        TokenPrefix(prefix: "ghr_", minLength: 20, issuer: "GitHub"),
        TokenPrefix(prefix: "github_pat_", minLength: 30, issuer: "GitHub"),
        // GitLab
        TokenPrefix(prefix: "glpat-", minLength: 20, issuer: "GitLab"),
        // OpenAI / Anthropic and the wider `sk-` convention
        TokenPrefix(prefix: "sk-ant-", minLength: 24, issuer: "Anthropic"),
        TokenPrefix(prefix: "sk-proj-", minLength: 24, issuer: "OpenAI"),
        TokenPrefix(prefix: "sk-", minLength: 24, issuer: "API key"),
        // Slack
        TokenPrefix(prefix: "xoxb-", minLength: 24, issuer: "Slack"),
        TokenPrefix(prefix: "xoxp-", minLength: 24, issuer: "Slack"),
        TokenPrefix(prefix: "xoxa-", minLength: 24, issuer: "Slack"),
        TokenPrefix(prefix: "xoxs-", minLength: 24, issuer: "Slack"),
        TokenPrefix(prefix: "xapp-", minLength: 24, issuer: "Slack"),
        // AWS key ids (fixed 20 chars, uppercase)
        TokenPrefix(prefix: "AKIA", minLength: 20, issuer: "AWS"),
        TokenPrefix(prefix: "ASIA", minLength: 20, issuer: "AWS"),
        // Google
        TokenPrefix(prefix: "AIza", minLength: 30, issuer: "Google"),
        TokenPrefix(prefix: "ya29.", minLength: 30, issuer: "Google OAuth"),
        // Stripe
        TokenPrefix(prefix: "sk_live_", minLength: 20, issuer: "Stripe"),
        TokenPrefix(prefix: "sk_test_", minLength: 20, issuer: "Stripe"),
        TokenPrefix(prefix: "rk_live_", minLength: 20, issuer: "Stripe"),
        TokenPrefix(prefix: "rk_test_", minLength: 20, issuer: "Stripe"),
        // Package registries + hosting
        TokenPrefix(prefix: "npm_", minLength: 24, issuer: "npm"),
        TokenPrefix(prefix: "pypi-", minLength: 30, issuer: "PyPI"),
        TokenPrefix(prefix: "hf_", minLength: 24, issuer: "Hugging Face"),
        TokenPrefix(prefix: "dop_v1_", minLength: 24, issuer: "DigitalOcean"),
        TokenPrefix(prefix: "doo_v1_", minLength: 24, issuer: "DigitalOcean"),
        TokenPrefix(prefix: "shpat_", minLength: 24, issuer: "Shopify"),
        TokenPrefix(prefix: "shpss_", minLength: 24, issuer: "Shopify"),
        TokenPrefix(prefix: "SG.", minLength: 30, issuer: "SendGrid"),
        // Tools this app already talks to
        TokenPrefix(prefix: "figd_", minLength: 24, issuer: "Figma"),
        TokenPrefix(prefix: "lin_api_", minLength: 24, issuer: "Linear"),
        TokenPrefix(prefix: "ntn_", minLength: 24, issuer: "Notion"),
    ]

    static func matchesTokenPrefix(_ token: String) -> Bool {
        tokenPrefixes.contains { token.hasPrefix($0.prefix) && token.count >= $0.minLength }
    }

    // MARK: - Individual rules (internal so each is testable on its own)

    /// One word: no spaces, tabs or newlines anywhere.
    static func isSingleToken(_ s: String) -> Bool {
        !s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// `header.payload.signature`, base64url segments, header starting `eyJ`.
    static func isJWT(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].hasPrefix("eyJ"), parts[0].count >= 10, parts[1].count >= 10 else {
            return false
        }
        let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { base64URL.contains($0) }
        }
    }

    /// `scheme://user:password@host`. An `@` with no `:` (a bare username, or a
    /// git `ssh://git@host` remote) is not a credential.
    static func containsURLCredential(_ s: String) -> Bool {
        guard let schemeRange = s.range(of: "://") else { return false }
        let rest = s[schemeRange.upperBound...]
        // Authority ends at the first `/`, `?` or whitespace.
        let authority = rest.prefix { $0 != "/" && $0 != "?" && !$0.isWhitespace }
        guard let atIndex = authority.lastIndex(of: "@") else { return false }
        let userInfo = authority[..<atIndex]
        guard let colonIndex = userInfo.firstIndex(of: ":") else { return false }
        let password = userInfo[userInfo.index(after: colonIndex)...]
        return !password.isEmpty
    }

    /// Secret-ish key names, matched case-insensitively against the left-hand
    /// side of an assignment. Shape, not provenance: the *text* names itself.
    static let secretKeyNames = [
        "api_key", "apikey", "api-key",
        "access_key", "accesskey", "access-key",
        "secret_key", "secretkey", "secret-key",
        "private_key", "privatekey", "private-key",
        "client_secret", "clientsecret", "client-secret",
        "session_key", "encryption_key",
        "secret", "token", "password", "passwd", "pwd",
        "credential", "credentials", "bearer", "auth_token", "authtoken",
    ]

    /// True when any line reads `<secret-name><=|:><value>` with a value that
    /// looks like data rather than code.
    static func containsSecretAssignment(_ text: String) -> Bool {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
            if lineIsSecretAssignment(String(rawLine)) { return true }
        }
        return false
    }

    static func lineIsSecretAssignment(_ line: String) -> Bool {
        // Split on the FIRST `=` or `:` — everything before is the name.
        guard let sepIndex = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return false }
        let rawName = line[..<sepIndex]
        let rawValue = line[line.index(after: sepIndex)...]

        // Normalise the name: strip quotes, `export `, whitespace, punctuation.
        let name = rawName
            .replacingOccurrences(of: "export ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`-"))
            .lowercased()
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard secretKeyNames.contains(where: { name.hasSuffix($0) }) else { return false }

        // Normalise the value: strip whitespace, then a trailing `,`/`;`, then
        // surrounding quotes. Remember whether it WAS quoted — a quoted value is
        // data, an unquoted bare identifier is usually code.
        var value = String(rawValue).trimmingCharacters(in: .whitespaces)
        while let last = value.last, last == "," || last == ";" { value.removeLast() }
        let wasQuoted = (value.count >= 2)
            && ((value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
                || (value.hasPrefix("`") && value.hasSuffix("`")))
        if wasQuoted { value = String(value.dropFirst().dropLast()) }

        guard value.count >= minAssignmentValueLength, isSingleToken(value) else { return false }
        guard !isPlaceholderValue(value) else { return false }

        // An unquoted, all-letter word is almost always an identifier being
        // assigned in code (`apiKey = apiKeyFromEnvironment`), not a secret.
        if !wasQuoted, value.allSatisfy({ $0.isLetter }) { return false }
        return true
    }

    /// Redacted / templated values that shouldn't trip the gate.
    static func isPlaceholderValue(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if value.hasPrefix("<"), value.hasSuffix(">") { return true }
        if value.hasPrefix("${"), value.hasSuffix("}") { return true }
        if value.hasPrefix("$") { return true }
        if lowered.hasPrefix("your_") || lowered.hasPrefix("your-") { return true }
        if lowered.hasPrefix("changeme") || lowered.hasPrefix("replace_me") { return true }
        // All one repeated character (xxxxxxxx, ********, ••••••••).
        if let first = value.first, value.allSatisfy({ $0 == first }) { return true }
        return false
    }

    /// A long run of hex — excluding the exact length of a git SHA-1, which is
    /// the single most-copied non-secret hex string in a developer's day.
    static func isHexBlob(_ s: String) -> Bool {
        guard s.count >= minHexBlobLength, s.count != gitSHALength else { return false }
        return s.allSatisfy(\.isHexDigit)
    }

    /// The fuzzy fallback: long, mixed-case, has a digit, high entropy, and none
    /// of the benign structures. Every clause is a precision lever — see the
    /// header note on why this is tuned tight.
    static func isRandomToken(_ s: String) -> Bool {
        guard s.count >= minRandomTokenLength else { return false }
        var hasUpper = false, hasLower = false, digits = 0, letters = 0
        for ch in s {
            if ch.isUppercase { hasUpper = true }
            if ch.isLowercase { hasLower = true }
            if ch.isNumber { digits += 1 }
            if ch.isLetter { letters += 1 }
        }
        guard hasUpper, hasLower, digits >= 1, letters >= 8 else { return false }
        return shannonEntropy(s) >= minRandomTokenEntropy
    }

    /// Structured strings that are long and look random but aren't secrets.
    /// Checked before the fuzzy rules only — a benign shape never overrides an
    /// exact prefix or a JWT.
    static func isBenignToken(_ s: String) -> Bool {
        if isUUID(s) { return true }
        if s.contains("://") { return true }              // a plain URL
        if s.hasPrefix("data:") { return true }           // data URI
        if s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".") { return true } // path
        if isEmail(s) { return true }
        if s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) { return true } // numbers/versions
        return false
    }

    /// 8-4-4-4-12 hex, with or without braces. Ids, not secrets.
    static func isUUID(_ s: String) -> Bool {
        var body = s
        if body.hasPrefix("{"), body.hasSuffix("}") { body = String(body.dropFirst().dropLast()) }
        let groups = body.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else { return false }
        let expected = [8, 4, 4, 4, 12]
        for (group, count) in zip(groups, expected) {
            guard group.count == count, group.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    static func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// Shannon entropy in bits per character over the observed frequencies.
    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in s { counts[ch, default: 0] += 1 }
        let total = Double(s.count)
        return counts.values.reduce(0.0) { acc, count in
            let p = Double(count) / total
            return acc - p * log2(p)
        }
    }
}
