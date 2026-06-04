//
//  UsageFormat.swift
//  Ghostwire
//
//  GW-151: compact strings for the usage meter. Minimal-text rule: these
//  are the only text the summary row shows; everything else is bar fill,
//  tint, and the detail view.
//

import Foundation

enum UsageFormat {
    /// 1_240_000 → "1.2M"
    static func tokenCount(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            value < 10
                ? String(format: "%.1f%@", value, suffix)
                : String(format: "%.0f%@", value, suffix)
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return scaled(Double(count) / 1_000, "k")
        case ..<1_000_000_000: return scaled(Double(count) / 1_000_000, "M")
        default: return scaled(Double(count) / 1_000_000_000, "B")
        }
    }

    private static let costFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// 4.8012 → "~$4.80" (estimate-flagged)
    static func estimatedCost(_ usd: Double) -> String {
        "~" + (costFormatter.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd))
    }

    /// Summary detail for token mode: spend when priced, tokens otherwise
    static func tokenSummary(_ tokens: AgentTokenDisplay) -> String {
        if let cost = tokens.estimatedCostUSD {
            return estimatedCost(cost)
        }
        let total = tokens.sevenDay.inputTokens + tokens.sevenDay.outputTokens
        return tokenCount(total) + " tok"
    }

    /// Which quota window a dual-mode bar shows. Session (5H) normally;
    /// switches to Weekly when 7D >=90% - the binding constraint - so the
    /// label always names the window on screen (label = timeframe rule).
    static func quotaBarSelection(fiveHour: QuotaPeriod?, sevenDay: QuotaPeriod?) -> (label: String, period: QuotaPeriod)? {
        if let sd = sevenDay, sd.utilization >= 90 {
            return ("Weekly", sd)
        }
        if let fh = fiveHour {
            return ("Session", fh)
        }
        if let sd = sevenDay {
            return ("Weekly", sd)
        }
        return nil
    }

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE h a"
        return f
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    /// Tooltip variant - whole single unit so "2h · 5h" stays as short as
    /// "API · 7d": rounded hours within a day, minutes under an hour, day
    /// name beyond 24h.
    static func resetTimeCompact(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "now" }
        if remaining >= 24 * 3600 { return dayOnlyFormatter.string(from: date) }
        if remaining >= 3600 { return "\(Int((remaining / 3600).rounded()))h" }
        return "\(Int(remaining) / 60)m"
    }

    /// "3h 57m" within a day, "Tue 9 AM" beyond (moved from AgentsTabView)
    static func resetTime(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            return dayTimeFormatter.string(from: date)
        }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
