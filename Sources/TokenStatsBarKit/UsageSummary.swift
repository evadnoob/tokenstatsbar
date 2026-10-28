import Foundation

struct PeriodTotals: Equatable {
    var cost: Double = 0
    var requests: Int = 0
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    var tokens: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ record: UsageRecord, cost recordCost: Double) {
        cost += recordCost
        requests += 1
        input += record.input
        output += record.output
        cacheRead += record.cacheRead
        cacheWrite += record.cacheWrite
    }
}

struct DailyCost: Equatable {
    var day: Date
    var cost: Double
}

/// The color family of a provider in the dropdown.
enum ProviderTint: Equatable {
    case orange, green, blue, pink, purple, gray
}

/// One provider and model with its cost today. The merged "other" row has no provider.
struct ModelCost: Equatable {
    var provider: String?
    var model: String
    var cost: Double

    var name: String { provider.map { "\($0)/\(model)" } ?? model }
    var isOther: Bool { provider == nil && model == UsageSummary.otherModelName }
}

struct UsageSummary: Equatable {
    var today = PeriodTotals()
    var sevenDays = PeriodTotals()
    var thisMonth = PeriodTotals()
    /// The last 14 days including today, oldest first.
    var daily: [DailyCost] = []
    /// Today's provider and model pairs, highest cost first.
    var modelsToday: [ModelCost] = []
    /// Today's Claude Code requests whose model is not in the price cache. Their cost is not in any total.
    var unpricedRequestsToday = 0

    static let sparklineDays = 14
    static let visibleModelCount = 4
    static let otherModelName = "other"

    /// Records that carry a cost (pi) use it. Others (Claude Code) are priced from `prices`, and nil means unpriced.
    /// A price entry without input and output prices counts as unpriced rather than free.
    static func cost(of record: UsageRecord, prices: [String: ModelPrice]) -> Double? {
        if let recorded = record.cost { return recorded }
        guard let price = PriceCache.price(for: record.model, in: prices),
              price.input != nil || price.output != nil else { return nil }
        return price.cost(of: record)
    }

    /// Pure aggregation by calendar day. `prices` is the current price cache.
    static func summarize(records: [UsageRecord], prices: [String: ModelPrice] = [:], now: Date,
                          calendar: Calendar) -> UsageSummary {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: startOfToday),
              let sparklineStart = calendar.date(byAdding: .day, value: -(sparklineDays - 1), to: startOfToday),
              let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return UsageSummary() }

        var summary = UsageSummary()
        var costByDay: [Date: Double] = [:]
        var costByModel: [String: ModelCost] = [:]
        for record in records where record.date < startOfTomorrow {
            let day = calendar.startOfDay(for: record.date)
            let pricedCost = cost(of: record, prices: prices)
            let recordCost = pricedCost ?? 0
            if day >= sparklineStart { costByDay[day, default: 0] += recordCost }
            if day >= monthStart { summary.thisMonth.add(record, cost: recordCost) }
            if day >= sevenDayStart { summary.sevenDays.add(record, cost: recordCost) }
            if day == startOfToday {
                summary.today.add(record, cost: recordCost)
                if pricedCost == nil { summary.unpricedRequestsToday += 1 }
                var row = ModelCost(provider: record.provider, model: record.model, cost: 0)
                row = costByModel[row.name] ?? row
                row.cost += recordCost
                costByModel[row.name] = row
            }
        }
        for offset in 0..<sparklineDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: sparklineStart) else { continue }
            summary.daily.append(DailyCost(day: day, cost: costByDay[day] ?? 0))
        }
        summary.modelsToday = costByModel.values
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.name < $1.name }
        return summary
    }

    /// The top rows plus one "other" row that sums the rest. No "other" row when everything fits.
    static func groupedModels(_ models: [ModelCost], limit: Int = visibleModelCount) -> [ModelCost] {
        guard models.count > limit else { return models }
        let rest = models[limit...].reduce(0) { $0 + $1.cost }
        return Array(models[..<limit]) + [ModelCost(provider: nil, model: otherModelName, cost: rest)]
    }

    /// Anthropic orange, OpenAI green, Google blue, xAI pink, any other provider purple.
    static func tint(forProvider provider: String) -> ProviderTint {
        let name = provider.lowercased()
        if name == "anthropic" { return .orange }
        if name.hasPrefix("openai") { return .green }
        if name.contains("google") || name.contains("gemini") || name.contains("vertex") { return .blue }
        if name == "xai" { return .pink }
        return .purple
    }
}
