//
//  UsageServiceParseTests.swift
//  GhostwireTests
//
//  GW-201: the Claude OAuth usage endpoint
//  (https://api.anthropic.com/api/oauth/usage) returns more than
//  five_hour/seven_day - per-model weeklies (seven_day_opus/sonnet) and an
//  extra_usage spend block, plus a rotating cast of codename fields
//  (tangelo, iguana_necktie, ...) that come and go. Parsing must be
//  DEFENSIVE: ignore unknown keys, tolerate nulls everywhere.
//  fullFixture is the exact live response verified 2026-06-04 (limits/credits
//  are in cents: $250 cap, $23.18 used → 9.272% util) - kept as the
//  legacy-shape compat fixture.
//  GW-314: july2026Fixture is the restructured live response verified
//  2026-07-22 - limits[] + spend{} are canonical, opus/sonnet nulled.
//

import XCTest
@testable import Ghostwire

final class UsageServiceParseTests: XCTestCase {

    private func parse(_ jsonString: String) throws -> UsageData {
        let data = jsonString.data(using: .utf8)!
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return UsageService.parseUsageData(from: json)
    }

    /// The full live fixture - every documented field populated.
    private let fullFixture = """
    {
      "five_hour": {"utilization": 29.0, "resets_at": "2026-06-04T12:20:00.964068+00:00"},
      "seven_day": {"utilization": 43.0, "resets_at": "2026-06-09T00:00:00+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": {"utilization": 2.0, "resets_at": "2026-06-09T00:00:00+00:00"},
      "seven_day_oauth_apps": null, "seven_day_cowork": null, "seven_day_omelette": null,
      "tangelo": null, "iguana_necktie": null, "omelette_promotional": null, "cinder_cove": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 25000, "used_credits": 2318.0, "utilization": 9.272, "currency": "USD", "disabled_reason": null}
    }
    """

    func testParsesFiveHourAndSevenDay() throws {
        let usage = try parse(fullFixture)
        XCTAssertEqual(usage.fiveHour?.utilization, 29.0)
        XCTAssertEqual(usage.sevenDay?.utilization, 43.0)
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
    }

    func testParsesPerModelWeeklies() throws {
        let usage = try parse(fullFixture)
        // opus is null in the fixture → must be nil, not zeroed
        XCTAssertNil(usage.sevenDayOpus)
        XCTAssertEqual(usage.sevenDaySonnet?.utilization, 2.0)
        XCTAssertNotNil(usage.sevenDaySonnet?.resetsAt)
    }

    func testParsesExtraUsage() throws {
        let usage = try parse(fullFixture)
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimitCents, 25000)
        XCTAssertEqual(extra.usedCredits, 2318.0)
        XCTAssertEqual(extra.utilization, 9.272, accuracy: 0.0001)
        // GW-203: currency is carried, not dropped (cents→dollars only valid for USD)
        XCTAssertEqual(extra.currency, "USD")
    }

    func testExtraUsageCurrencyDefaultsToUSDWhenAbsent() throws {
        let usage = try parse("""
        { "extra_usage": {"is_enabled": true, "monthly_limit": 25000, "used_credits": 100.0, "utilization": 0.4} }
        """)
        XCTAssertEqual(usage.extraUsage?.currency, "USD")
    }

    func testDecodesCachedExtraUsageWrittenBeforeCurrencyExisted() throws {
        // Codex review P3: a pre-GW-203 usage-cache.json has no `currency`
        // key; synthesized decoding would throw and blank the whole cache.
        let legacyCache = Data("""
        {"isEnabled": true, "monthlyLimitCents": 25000, "usedCredits": 2318.0, "utilization": 9.272}
        """.utf8)
        let extra = try JSONDecoder().decode(ExtraUsage.self, from: legacyCache)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimitCents, 25000)
        XCTAssertEqual(extra.currency, "USD")
    }

    // MARK: - GW-203: per-model + extra ride the display enum's .quota case

    func testQuotaDisplayCarriesPerModelAndExtra() throws {
        let usage = try parse(fullFixture)
        guard case .quota(let fiveHour, let sevenDay, let perModel, let extra) = usage.quotaDisplay else {
            return XCTFail("expected .quota, got \(usage.quotaDisplay)")
        }
        XCTAssertEqual(fiveHour?.utilization, 29.0)
        XCTAssertEqual(sevenDay?.utilization, 43.0)
        // opus null → dropped; sonnet present → carried (only non-null weeklies)
        XCTAssertEqual(perModel.map(\.label), ["Sonnet"])
        XCTAssertEqual(perModel.first?.period.utilization, 2.0)
        XCTAssertEqual(extra?.usedCredits, 2318.0)
    }

    func testQuotaDisplayDropsNullWeeklies() throws {
        let usage = try parse("""
        { "five_hour": {"utilization": 5.0}, "seven_day": {"utilization": 10.0} }
        """)
        guard case .quota(_, _, let perModel, let extra) = usage.quotaDisplay else {
            return XCTFail("expected .quota")
        }
        XCTAssertTrue(perModel.isEmpty)
        XCTAssertNil(extra)
    }

    func testIgnoresUnknownCodenameKeys() throws {
        // tangelo/iguana_necktie/etc. must not crash or leak into anything
        let usage = try parse(fullFixture)
        XCTAssertNotNil(usage.fiveHour)
        XCTAssertNotNil(usage.extraUsage)
    }

    func testExtraUsageNullYieldsNil() throws {
        let usage = try parse("""
        {
          "five_hour": {"utilization": 10.0, "resets_at": null},
          "seven_day": {"utilization": 20.0, "resets_at": null},
          "extra_usage": null
        }
        """)
        XCTAssertNil(usage.extraUsage)
        XCTAssertEqual(usage.fiveHour?.utilization, 10.0)
    }

    func testExtraUsageDisabledStillParses() throws {
        // is_enabled false → still parse it (the view decides not to render)
        let usage = try parse("""
        {
          "five_hour": {"utilization": 1.0, "resets_at": null},
          "extra_usage": {"is_enabled": false, "monthly_limit": 25000, "used_credits": 0.0, "utilization": 0.0, "currency": "USD", "disabled_reason": "not_eligible"}
        }
        """)
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertFalse(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimitCents, 25000)
    }

    func testExtraUsageMissingFieldsTolerated() throws {
        // partial extra_usage block: only is_enabled present → defaults fill in
        let usage = try parse("""
        {
          "extra_usage": {"is_enabled": true}
        }
        """)
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.monthlyLimitCents, 0)
        XCTAssertEqual(extra.usedCredits, 0)
        XCTAssertEqual(extra.utilization, 0)
    }

    func testAllNullYieldsEmptyData() throws {
        let usage = try parse("""
        {
          "five_hour": null, "seven_day": null,
          "seven_day_opus": null, "seven_day_sonnet": null,
          "extra_usage": null
        }
        """)
        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
        XCTAssertNil(usage.sevenDayOpus)
        XCTAssertNil(usage.sevenDaySonnet)
        XCTAssertNil(usage.extraUsage)
    }

    func testEmptyObjectYieldsEmptyData() throws {
        let usage = try parse("{}")
        XCTAssertEqual(usage, UsageData.empty)
    }

    /// Integer utilization (server sometimes sends 0 not 0.0) must still parse.
    func testIntegerUtilizationParses() throws {
        let usage = try parse("""
        {
          "five_hour": {"utilization": 0, "resets_at": null},
          "extra_usage": {"is_enabled": true, "monthly_limit": 25000, "used_credits": 0, "utilization": 0, "currency": "USD"}
        }
        """)
        XCTAssertEqual(usage.fiveHour?.utilization, 0)
        XCTAssertEqual(usage.extraUsage?.usedCredits, 0)
    }

    // MARK: - GW-314: limits[]/spend{} restructure (live shape 2026-07-22)

    /// Exact live response verified 2026-07-22: seven_day_opus/sonnet nulled,
    /// per-model weeklies moved into limits[] (weekly_scoped + scope.model),
    /// new canonical spend{} block in minor units. Legacy five_hour/seven_day
    /// still populated - for now.
    private let july2026Fixture = """
    {
      "five_hour": {"utilization": 34.0, "resets_at": "2026-07-22T12:10:00.964068+00:00", "limit_dollars": null},
      "seven_day": {"utilization": 10.0, "resets_at": "2026-07-28T14:00:00+00:00"},
      "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_oauth_apps": null,
      "nimbus_quill": null, "amber_ladder": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 25000, "used_credits": 5585.0, "utilization": 22.34, "currency": "USD", "decimal_places": 2, "daily": null, "weekly": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 34, "severity": "normal", "resets_at": "2026-07-22T12:10:00.964068+00:00", "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 10, "severity": "normal", "resets_at": "2026-07-28T14:00:00+00:00", "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 17, "severity": "normal", "resets_at": "2026-07-28T14:00:00+00:00", "is_active": false, "scope": {"model": {"id": null, "display_name": "Fable"}}}
      ],
      "spend": {"used": {"amount_minor": 5585, "currency": "USD", "exponent": 2}, "limit": {"amount_minor": 25000, "currency": "USD", "exponent": 2}, "percent": 22}
    }
    """

    func testJuly2026FixtureParsesSessionAndWeekly() throws {
        let usage = try parse(july2026Fixture)
        XCTAssertEqual(usage.fiveHour?.utilization, 34.0)
        XCTAssertEqual(usage.sevenDay?.utilization, 10.0)
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
        XCTAssertNotNil(usage.sevenDay?.resetsAt)
    }

    func testWeeklyScopedLimitsBecomePerModelWeeklies() throws {
        let usage = try parse(july2026Fixture)
        XCTAssertEqual(usage.perModelWeeklies.map(\.label), ["Fable"])
        XCTAssertEqual(usage.perModelWeeklies.first?.period.utilization, 17.0)
        XCTAssertNotNil(usage.perModelWeeklies.first?.period.resetsAt)
        // legacy per-model fields are null on the wire → stay nil
        XCTAssertNil(usage.sevenDayOpus)
        XCTAssertNil(usage.sevenDaySonnet)
    }

    /// limits[] is the primary source - when it disagrees with the legacy
    /// compat fields, limits[] wins (legacy looks like a deprecated shim).
    func testLimitsTakePrecedenceOverLegacyFields() throws {
        let usage = try parse("""
        {
          "five_hour": {"utilization": 50.0, "resets_at": null},
          "seven_day": {"utilization": 60.0, "resets_at": null},
          "limits": [
            {"kind": "session", "group": "session", "percent": 34, "resets_at": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 10, "resets_at": null, "is_active": false}
          ]
        }
        """)
        XCTAssertEqual(usage.fiveHour?.utilization, 34.0)
        XCTAssertEqual(usage.sevenDay?.utilization, 10.0)
    }

    /// The anticipated hard break: legacy fields dropped entirely, only
    /// limits[] remains. Quota bars must keep working.
    func testLimitsOnlyResponseParses() throws {
        let usage = try parse("""
        {
          "limits": [
            {"kind": "session", "group": "session", "percent": 34, "resets_at": "2026-07-22T12:10:00+00:00", "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 10, "resets_at": "2026-07-28T14:00:00+00:00", "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 17, "resets_at": "2026-07-28T14:00:00+00:00", "is_active": false, "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
        """)
        XCTAssertEqual(usage.fiveHour?.utilization, 34.0)
        XCTAssertEqual(usage.sevenDay?.utilization, 10.0)
        XCTAssertEqual(usage.perModelWeeklies.map(\.label), ["Fable"])
    }

    /// A weekly_scoped entry without a model display name can't be labeled -
    /// skip it rather than rendering an anonymous bar.
    func testWeeklyScopedWithoutDisplayNameSkipped() throws {
        let usage = try parse("""
        {
          "limits": [
            {"kind": "weekly_scoped", "group": "weekly", "percent": 17, "resets_at": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 9, "resets_at": null, "is_active": false, "scope": {"model": {"id": "claude-opus-4-8", "display_name": "Opus"}}}
          ]
        }
        """)
        XCTAssertEqual(usage.perModelWeeklies.map(\.label), ["Opus"])
    }

    func testQuotaDisplayPrefersScopedWeekliesOverLegacy() throws {
        let usage = try parse(july2026Fixture)
        guard case .quota(_, _, let perModel, let extra) = usage.quotaDisplay else {
            return XCTFail("expected .quota")
        }
        XCTAssertEqual(perModel.map(\.label), ["Fable"])
        XCTAssertEqual(perModel.first?.period.utilization, 17.0)
        // extra_usage still populated on the live wire → preferred over spend{}
        XCTAssertEqual(extra?.usedCredits, 5585.0)
        XCTAssertEqual(extra?.utilization ?? 0, 22.34, accuracy: 0.0001)
    }

    /// spend{} is the fallback when extra_usage disappears: minor units with
    /// exponent normalize to the cents ExtraUsage carries.
    func testSpendFallbackWhenExtraUsageMissing() throws {
        let usage = try parse("""
        {
          "extra_usage": null,
          "spend": {"used": {"amount_minor": 5585, "currency": "USD", "exponent": 2}, "limit": {"amount_minor": 25000, "currency": "USD", "exponent": 2}, "percent": 22}
        }
        """)
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertTrue(extra.isEnabled)
        XCTAssertEqual(extra.usedCredits, 5585.0)
        XCTAssertEqual(extra.monthlyLimitCents, 25000)
        XCTAssertEqual(extra.utilization, 22.0)
        XCTAssertEqual(extra.currency, "USD")
    }

    /// exponent != 2 must normalize to cents ($55 with exponent 0 → 5500¢).
    func testSpendExponentNormalizesToCents() throws {
        let usage = try parse("""
        {
          "spend": {"used": {"amount_minor": 55, "currency": "USD", "exponent": 0}, "limit": {"amount_minor": 250, "currency": "USD", "exponent": 0}, "percent": 22}
        }
        """)
        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertEqual(extra.usedCredits, 5500.0)
        XCTAssertEqual(extra.monthlyLimitCents, 25000)
    }

    /// A usage-cache.json written before perModelWeeklies existed must still
    /// decode (same trap as the ExtraUsage.currency migration).
    func testDecodesCachedUsageDataWithoutPerModelWeeklies() throws {
        let legacyCache = Data("""
        {"fiveHour": {"utilization": 29.0, "resetsAt": null}, "sevenDay": {"utilization": 43.0, "resetsAt": null}}
        """.utf8)
        let usage = try JSONDecoder().decode(UsageData.self, from: legacyCache)
        XCTAssertEqual(usage.fiveHour?.utilization, 29.0)
        XCTAssertTrue(usage.perModelWeeklies.isEmpty)
    }

    // MARK: - GW-314: staleness rule

    func testStaleWhenLastFetchExceedsThreshold() {
        let now = Date()
        XCTAssertTrue(UsageService.isStale(lastFetch: now.addingTimeInterval(-601), now: now))
        XCTAssertFalse(UsageService.isStale(lastFetch: now.addingTimeInterval(-300), now: now))
    }

    func testNeverFetchedIsNotStale() {
        // nil = nothing displayed yet - there's no stale number on screen
        XCTAssertFalse(UsageService.isStale(lastFetch: nil, now: Date()))
    }
}
