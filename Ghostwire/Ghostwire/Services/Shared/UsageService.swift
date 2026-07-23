import Combine
import Foundation
import os
import Security

// MARK: - Models

struct UsageData: Equatable, Codable {
    var fiveHour: QuotaPeriod?
    var sevenDay: QuotaPeriod?
    /// GW-201: per-model weekly sub-limits (null on the wire when the plan
    /// doesn't expose them - keep nil, don't zero). GW-314: the server nulled
    /// these in the 2026-07 restructure - kept as the legacy fallback only.
    var sevenDayOpus: QuotaPeriod?
    var sevenDaySonnet: QuotaPeriod?
    /// GW-314: model-scoped weeklies from the new limits[] array
    /// (kind == weekly_scoped, labeled by scope.model.display_name) - the
    /// primary per-model source since the 2026-07 restructure.
    var perModelWeeklies: [PerModelQuota] = []
    /// GW-201: server-provided extra-usage spend (monthly $ cap + used)
    var extraUsage: ExtraUsage?

    static let empty = UsageData()

    /// GW-203: the full .quota display for this data - per-model weeklies and
    /// extra-usage spend ride the enum so the UI never reaches back into
    /// UsageService.usage (the GW-201 side channel that forced agent-name
    /// gates). Only non-null weeklies are surfaced.
    /// GW-314: limits[]-scoped weeklies win; opus/sonnet legacy fields are
    /// the fallback for as long as the server still populates them.
    var quotaDisplay: AgentUsageDisplay {
        var perModel = perModelWeeklies
        if perModel.isEmpty {
            if let opus = sevenDayOpus { perModel.append(PerModelQuota(label: "Opus", period: opus)) }
            if let sonnet = sevenDaySonnet { perModel.append(PerModelQuota(label: "Sonnet", period: sonnet)) }
        }
        return .quota(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            perModel: perModel,
            extra: extraUsage
        )
    }
}

extension UsageData {
    /// Custom decode so a usage-cache.json written before `perModelWeeklies`
    /// existed still loads (same migration trap as ExtraUsage.currency:
    /// synthesized Codable fails the whole cached object, blanking the meter
    /// on startup until a network fetch). Extension keeps the memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(QuotaPeriod.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(QuotaPeriod.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(QuotaPeriod.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(QuotaPeriod.self, forKey: .sevenDaySonnet)
        perModelWeeklies = try container.decodeIfPresent([PerModelQuota].self, forKey: .perModelWeeklies) ?? []
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
    }
}

/// extra_usage block from the OAuth usage endpoint - server-truth billing,
/// in cents ($250 cap = 25000). Parsed even when disabled; views decide.
struct ExtraUsage: Equatable, Codable {
    var isEnabled: Bool = false
    var monthlyLimitCents: Int = 0
    var usedCredits: Double = 0
    var utilization: Double = 0
    /// GW-203: carried from the wire (e.g. "USD") instead of dropped - the
    /// cents assumption in spendDetail only holds while this is USD.
    var currency: String = "USD"
}

extension ExtraUsage {
    /// Custom decode so a usage-cache.json written before `currency` existed
    /// still loads (synthesized Codable would fail the whole cached object,
    /// blanking quota/spend on startup until a network fetch). Lives in an
    /// extension to keep the memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        monthlyLimitCents = try container.decodeIfPresent(Int.self, forKey: .monthlyLimitCents) ?? 0
        usedCredits = try container.decodeIfPresent(Double.self, forKey: .usedCredits) ?? 0
        utilization = try container.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
    }
}

struct QuotaPeriod: Equatable, Codable {
    let utilization: Double     // 0-100
    let resetsAt: Date?
}

// MARK: - Usage Service

@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var usage = UsageData.empty
    @Published private(set) var isAvailable = false
    /// GW-151: auth-branched display - .quota when OAuth creds exist (the
    /// existing endpoint path), .tokens aggregated from local transcripts
    /// when the user is API-key-only. Same shape as CodexUsageService.
    @Published private(set) var display: AgentUsageDisplay?
    /// GW-314: when the displayed quota data was last confirmed against the
    /// server (network fetch, or the cache's fetchedAt on startup). Nil until
    /// anything loads.
    @Published private(set) var lastSuccessfulFetch: Date?
    /// GW-314: true when quota numbers on screen are older than the stale
    /// threshold - failed polls used to be swallowed silently, so a maxed
    /// account could show hours-old headroom with no hint. Re-evaluated on
    /// every poll completion (success, failure, or backoff).
    @Published private(set) var isStale = false

    private let logger = os.Logger(subsystem: "com.ghostwire.notch", category: "UsageService")
    private let tokenParser = ClaudeTokenUsageParser()

    private var pollTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private let baseInterval: TimeInterval = 300
    private var currentInterval: TimeInterval = 300
    private var backoffCount = 0
    private var consecutiveFailures = 0

    nonisolated(unsafe) private static let isoFormatterFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterBasic = ISO8601DateFormatter()

    private init() {}

    func startPolling() {
        guard pollTimer == nil else { return }
        loadCache()
        poll()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTask?.cancel()
        pollTask = nil
        backoffCount = 0
        consecutiveFailures = 0
        currentInterval = baseInterval
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    private func poll() {
        pollTask = Task {
            guard let token = Self.readOAuthToken() else {
                // GW-151: no OAuth → API-key user → token mode from local
                // transcripts (subscription quota only exists behind OAuth)
                await pollTokenMode()
                scheduleNextPoll()
                return
            }

            if !isAvailable { isAvailable = true }

            do {
                let result = try await Self.fetchUsage(token: token)
                usage = result
                display = result.quotaDisplay
                lastSuccessfulFetch = Date()
                isStale = false
                consecutiveFailures = 0
                backoffCount = 0
                currentInterval = baseInterval
                saveCache()
            } catch let error as URLError where error.code.rawValue == 429 {
                backoffCount += 1
                currentInterval = min(1800, baseInterval * pow(2.0, Double(backoffCount)))
                // GW-314: backoff can stretch to 30 min - that gap is real
                // staleness, surface it instead of silently coasting
                logger.warning("usage poll rate-limited (429), backing off to \(Int(self.currentInterval))s")
                refreshStaleness()
            } catch {
                consecutiveFailures += 1
                // GW-314: failures were fully swallowed before - the meter
                // kept rendering the last snapshot as if live
                logger.warning("usage poll failed (\(self.consecutiveFailures) consecutive): \(error.localizedDescription)")
                refreshStaleness()
                if consecutiveFailures > 5 && usage.fiveHour == nil && usage.sevenDay == nil {
                    isAvailable = false
                }
            }
            scheduleNextPoll()
        }
    }

    /// API-key mode: aggregate transcript usage{} into 5H/7D token totals
    /// (ClaudeTokenUsageParser - tested) + estimated cost (AgentCostTable).
    private func pollTokenMode() async {
        let parser = tokenParser
        let snapshot = await Task.detached(priority: .utility) {
            parser.snapshot(now: Date())
        }.value

        guard !Task.isCancelled else { return }
        guard snapshot.hasData else {
            isAvailable = false
            display = nil
            return
        }

        isAvailable = true
        display = .tokens(AgentTokenDisplay(
            fiveHour: snapshot.fiveHour,
            sevenDay: snapshot.sevenDay,
            estimatedCostUSD: AgentCostTable.estimateUSD(tokensByModel: snapshot.tokensByModel)
        ))
    }

    // MARK: - Cache

    private static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Ghostwire", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-cache.json")
    }()

    private struct CachedUsage: Codable {
        let usage: UsageData
        let fetchedAt: Date
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode(CachedUsage.self, from: data) else { return }
        usage = cached.usage
        display = cached.usage.quotaDisplay
        isAvailable = true
        // GW-314: honor the cache's real age - an any-age snapshot used to
        // render as current on launch with no staleness signal
        lastSuccessfulFetch = cached.fetchedAt
        refreshStaleness()
    }

    // MARK: - Staleness (GW-314)

    /// Two missed polls = stale. The pure rule is static for testability.
    static let staleThreshold: TimeInterval = 600

    nonisolated static func isStale(lastFetch: Date?, now: Date) -> Bool {
        guard let lastFetch else { return false } // nothing on screen to be stale
        return now.timeIntervalSince(lastFetch) > staleThreshold
    }

    private func refreshStaleness() {
        isStale = Self.isStale(lastFetch: lastSuccessfulFetch, now: Date())
    }

    private func saveCache() {
        let cached = CachedUsage(usage: usage, fetchedAt: Date())
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Keychain

    private static func readOAuthToken() -> String? {
        // Primary: /usr/bin/security CLI (avoids ACL dialog)
        if let json = readKeychainViaCLI(),
           let token = extractToken(from: json) {
            return token
        }

        // Fallback: Security.framework
        if let json = readKeychainViaFramework(),
           let token = extractToken(from: json) {
            return token
        }

        return nil
    }

    private static func readKeychainViaCLI() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func readKeychainViaFramework() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func extractToken(from json: [String: Any]) -> String? {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawToken = oauth["accessToken"] as? String else { return nil }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: - API Call

    private static func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard http.statusCode == 200 else {
            throw URLError(.init(rawValue: http.statusCode))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        return parseUsageData(from: json)
    }

    /// GW-201: full response parse, extracted for testability. DEFENSIVE by
    /// design - the endpoint carries rotating codename fields (tangelo,
    /// iguana_necktie, ...); ignore unknown keys, tolerate nulls everywhere.
    /// GW-314 (2026-07 restructure): the canonical source is now the limits[]
    /// array (kind: session | weekly_all | weekly_scoped) + spend{}; the flat
    /// five_hour/seven_day/extra_usage fields look like a deprecated compat
    /// shim (seven_day_opus/sonnet already nulled) - parse limits[] first,
    /// fall back to the legacy fields so either shape alone still works.
    nonisolated static func parseUsageData(from json: [String: Any]) -> UsageData {
        let limits = parseLimits(json["limits"])
        return UsageData(
            fiveHour: limits.session ?? parseQuotaPeriod(json["five_hour"]),
            sevenDay: limits.weeklyAll ?? parseQuotaPeriod(json["seven_day"]),
            sevenDayOpus: parseQuotaPeriod(json["seven_day_opus"]),
            sevenDaySonnet: parseQuotaPeriod(json["seven_day_sonnet"]),
            perModelWeeklies: limits.weeklyScoped,
            extraUsage: parseExtraUsage(json["extra_usage"]) ?? parseSpend(json["spend"])
        )
    }

    /// GW-314: limits[] entries -
    /// {kind, group, percent (int 0-100), severity, resets_at, is_active,
    ///  scope?: {model: {id, display_name}}}.
    /// Unknown kinds are ignored (same defensive posture as codename fields);
    /// weekly_scoped entries without a model display name are skipped rather
    /// than rendered as an anonymous bar.
    nonisolated private static func parseLimits(_ value: Any?)
        -> (session: QuotaPeriod?, weeklyAll: QuotaPeriod?, weeklyScoped: [PerModelQuota]) {
        guard let entries = value as? [[String: Any]] else { return (nil, nil, []) }

        var session: QuotaPeriod?
        var weeklyAll: QuotaPeriod?
        var weeklyScoped: [PerModelQuota] = []

        for entry in entries {
            guard let kind = entry["kind"] as? String,
                  let percent = entry["percent"] as? Double else { continue }
            let period = QuotaPeriod(utilization: percent, resetsAt: parseResetsAt(entry["resets_at"]))

            switch kind {
            case "session":
                session = session ?? period
            case "weekly_all":
                weeklyAll = weeklyAll ?? period
            case "weekly_scoped":
                guard let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let label = model["display_name"] as? String, !label.isEmpty else { continue }
                weeklyScoped.append(PerModelQuota(label: label, period: period))
            default:
                continue
            }
        }
        return (session, weeklyAll, weeklyScoped)
    }

    /// GW-314: spend{} fallback for when extra_usage disappears -
    /// {used: {amount_minor, currency, exponent}, limit: {...}, percent}.
    /// amount_minor normalizes to the cents ExtraUsage carries via the
    /// exponent (2 → already cents; 0 → whole units × 100).
    nonisolated private static func parseSpend(_ value: Any?) -> ExtraUsage? {
        guard let dict = value as? [String: Any],
              let used = dict["used"] as? [String: Any],
              let usedMinor = used["amount_minor"] as? Double else { return nil }
        let limit = dict["limit"] as? [String: Any]

        func cents(_ amountMinor: Double, exponent: Any?) -> Double {
            let exp = exponent as? Int ?? 2
            return amountMinor * pow(10.0, Double(2 - exp))
        }

        return ExtraUsage(
            isEnabled: true,
            monthlyLimitCents: Int(cents((limit?["amount_minor"] as? Double) ?? 0, exponent: limit?["exponent"])),
            usedCredits: cents(usedMinor, exponent: used["exponent"]),
            utilization: dict["percent"] as? Double ?? 0,
            currency: used["currency"] as? String ?? "USD"
        )
    }

    nonisolated private static func parseExtraUsage(_ value: Any?) -> ExtraUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        return ExtraUsage(
            isEnabled: dict["is_enabled"] as? Bool ?? false,
            monthlyLimitCents: dict["monthly_limit"] as? Int ?? 0,
            usedCredits: dict["used_credits"] as? Double ?? 0,
            utilization: dict["utilization"] as? Double ?? 0,
            currency: dict["currency"] as? String ?? "USD"
        )
    }

    nonisolated private static func parseQuotaPeriod(_ value: Any?) -> QuotaPeriod? {
        guard let dict = value as? [String: Any],
              let utilization = dict["utilization"] as? Double else { return nil }
        return QuotaPeriod(utilization: utilization, resetsAt: parseResetsAt(dict["resets_at"]))
    }

    nonisolated private static func parseResetsAt(_ value: Any?) -> Date? {
        guard let dateStr = value as? String else { return nil }
        return isoFormatterFrac.date(from: dateStr) ?? isoFormatterBasic.date(from: dateStr)
    }
}
