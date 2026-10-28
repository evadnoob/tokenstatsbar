import Foundation

struct PeriodTotals: Equatable {
    var cost: Double = 0
    var requests: Int = 0
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    var tokens: Int { input + output + cacheRead + cacheWrite }

    mutating func add(_ record: UsageRecord) {
        cost += record.cost
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

struct ModelCost: Equatable {
    var model: String
    var cost: Double
}

struct UsageSummary: Equatable {
    var today = PeriodTotals()
    var sevenDays = PeriodTotals()
    var thisMonth = PeriodTotals()
    /// The last 14 days including today, oldest first.
    var daily: [DailyCost] = []
    /// Today's models, highest cost first.
    var modelsToday: [ModelCost] = []

    static let sparklineDays = 14
    static let visibleModelCount = 3
    static let otherModelName = "other"

    /// Pure aggregation by calendar day. `now` and `calendar` are parameters so tests can fix them.
    static func summarize(records: [UsageRecord], now: Date, calendar: Calendar) -> UsageSummary {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: startOfToday),
              let sparklineStart = calendar.date(byAdding: .day, value: -(sparklineDays - 1), to: startOfToday),
              let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return UsageSummary() }

        var summary = UsageSummary()
        var costByDay: [Date: Double] = [:]
        var costByModel: [String: Double] = [:]
        for record in records where record.date < startOfTomorrow {
            let day = calendar.startOfDay(for: record.date)
            if day >= sparklineStart { costByDay[day, default: 0] += record.cost }
            if day >= monthStart { summary.thisMonth.add(record) }
            if day >= sevenDayStart { summary.sevenDays.add(record) }
            if day == startOfToday {
                summary.today.add(record)
                costByModel[record.model, default: 0] += record.cost
            }
        }
        for offset in 0..<sparklineDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: sparklineStart) else { continue }
            summary.daily.append(DailyCost(day: day, cost: costByDay[day] ?? 0))
        }
        summary.modelsToday = costByModel
            .map { ModelCost(model: $0.key, cost: $0.value) }
            .sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.model < $1.model }
        return summary
    }

    /// The top models plus one "other" row that sums the rest. No "other" row when everything fits.
    static func groupedModels(_ models: [ModelCost], limit: Int = visibleModelCount) -> [ModelCost] {
        guard models.count > limit else { return models }
        let rest = models[limit...].reduce(0) { $0 + $1.cost }
        return Array(models[..<limit]) + [ModelCost(model: otherModelName, cost: rest)]
    }
}
