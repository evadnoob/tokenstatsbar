import Foundation

/// The numbers of one source inside a selection.
struct SourceBreakdown: Equatable {
    var source: UsageSource
    var requests = 0
    var totalTokens = 0
    /// nil when no request of this source could be priced.
    var cost: Double?
}

/// One local calendar day of a selection, for the sparkline.
struct DailyUsagePoint: Equatable, Identifiable {
    var day: Date
    var cost: Double
    var totalTokens: Int

    var id: Date { day }
}

/// The numbers behind the side panel: everything, one provider, or one provider and model.
struct SelectionDetails: Equatable {
    var requests = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// nil when no request could be priced.
    var cost: Double?
    /// pi first, then Claude Code. Only sources that have requests are listed.
    var sources: [SourceBreakdown] = []
    /// The last 14 days including today, oldest first. The range does not limit it.
    var daily: [DailyUsagePoint] = []

    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    static let sparklineDays = 14

    /// `provider` nil selects every provider, and `model` nil selects every model of the provider.
    static func summarize(records: [UsageRecord], prices: [String: ModelPrice], range: DetailsRange,
                          source: DetailsSourceFilter, provider: String?, model: String?, now: Date,
                          calendar: Calendar) -> SelectionDetails {
        var details = SelectionDetails()
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let firstDay = calendar.date(byAdding: .day, value: 1 - sparklineDays, to: startOfToday) else {
            return details
        }
        let rangeStart = range.start(now: now, calendar: calendar)
        var costByDay: [Date: Double] = [:]
        var tokensByDay: [Date: Int] = [:]
        var breakdowns: [UsageSource: SourceBreakdown] = [:]
        for record in records where record.date < startOfTomorrow && source.includes(record.source) {
            if let provider, record.provider != provider { continue }
            if let model, record.model != model { continue }
            let pricedCost = UsageSummary.cost(of: record, prices: prices)
            let day = calendar.startOfDay(for: record.date)
            if day >= firstDay {
                costByDay[day, default: 0] += pricedCost ?? 0
                tokensByDay[day, default: 0] += record.totalTokens
            }
            if let rangeStart, record.date < rangeStart { continue }
            details.requests += 1
            details.input += record.input
            details.output += record.output
            details.cacheRead += record.cacheRead
            details.cacheWrite += record.cacheWrite
            if let pricedCost { details.cost = (details.cost ?? 0) + pricedCost }
            var breakdown = breakdowns[record.source] ?? SourceBreakdown(source: record.source)
            breakdown.requests += 1
            breakdown.totalTokens += record.totalTokens
            if let pricedCost { breakdown.cost = (breakdown.cost ?? 0) + pricedCost }
            breakdowns[record.source] = breakdown
        }
        details.sources = [UsageSource.pi, .claudeCode].compactMap { breakdowns[$0] }
        for offset in 0..<sparklineDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            details.daily.append(DailyUsagePoint(day: day, cost: costByDay[day] ?? 0, totalTokens: tokensByDay[day] ?? 0))
        }
        return details
    }
}
