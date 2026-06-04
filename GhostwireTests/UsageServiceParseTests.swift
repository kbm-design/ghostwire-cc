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
//  Fixture is the exact live response verified 2026-06-04 (limits/credits
//  are in cents: $250 cap, $23.18 used → 9.272% util).
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
}
