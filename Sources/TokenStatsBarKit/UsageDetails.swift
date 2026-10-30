import Foundation

/// The time range of the details window. Day boundaries match UsageSummary: local calendar days.
enum DetailsRange: String, CaseIterable, Identifiable {
    case today
    case sevenDays
    case thisMonth
    case thirtyOneDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thisMonth: return "This month"
        case .thirtyOneDays: return "31 days"
        }
    }

    /// The wording of the range in the headline of the details window.
    var headlineTitle: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "Last 7 days"
        case .thisMonth: return "This month"
        case .thirtyOneDays: return "Last 31 days"
        }
    }

    /// The first instant of the range, or nil when the range has no lower bound (everything kept, 31 days).
    func start(now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today: return startOfToday
        case .sevenDays: return calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)?.start
        case .thirtyOneDays: return nil
        }
    }
}

enum DetailsSourceFilter: String, CaseIterable, Identifiable {
    case all
    case pi
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .pi: return "pi"
        case .claudeCode: return "Claude Code"
        }
    }

    func includes(_ source: UsageSource) -> Bool {
        switch self {
        case .all: return true
        case .pi: return source == .pi
        case .claudeCode: return source == .claudeCode
        }
    }
}

enum DetailsColumn: Equatable {
    case name, requests, input, output, cacheRead, cacheWrite, totalTokens, cost, share
}

/// One provider and model in the table.
struct UsageDetailRow: Equatable, Identifiable {
    var provider: String
    var model: String
    var requests = 0
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// nil when no request of this model could be priced.
    var cost: Double?
    /// Percent of the total priced cost, 0 for an unpriced model.
    var share = 0.0

    var name: String { "\(provider)/\(model)" }
    var id: String { name }
    var totalTokens: Int { input + output + cacheRead + cacheWrite }
    /// Unpriced sorts as the lowest cost.
    var costSortValue: Double { cost ?? -1 }
}

/// Cost of one provider and model (or "other") in one hour or day bucket.
struct UsageChartPoint: Equatable, Identifiable {
    var bucketStart: Date
    var name: String
    var cost: Double

    var id: String { "\(bucketStart.timeIntervalSince1970)/\(name)" }
}

struct UsageDetails: Equatable {
    var rows: [UsageDetailRow] = []
    var totals = PeriodTotals()
    var unpricedRequests = 0
    var chartPoints: [UsageChartPoint] = []
    /// True when the chart buckets are hours (Today) and false when they are days.
    var isHourly = false

    static let visibleChartModelCount = 8

    /// Pure aggregation of the records inside `range` and `source`. `prices` is the current price cache.
    static func summarize(records: [UsageRecord], prices: [String: ModelPrice], range: DetailsRange,
                          source: DetailsSourceFilter, now: Date, calendar: Calendar) -> UsageDetails {
        let start = range.start(now: now, calendar: calendar)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return UsageDetails()
        }
        let isHourly = range == .today
        var details = UsageDetails(isHourly: isHourly)
        var rowsByName: [String: UsageDetailRow] = [:]
        var costByBucketAndName: [Date: [String: Double]] = [:]
        var costByName: [String: Double] = [:]
        for record in records where record.date < startOfTomorrow && source.includes(record.source) {
            if let start, record.date < start { continue }
            let pricedCost = UsageSummary.cost(of: record, prices: prices)
            details.totals.add(record, cost: pricedCost ?? 0)
            if pricedCost == nil { details.unpricedRequests += 1 }

            var row = UsageDetailRow(provider: record.provider, model: record.model)
            row = rowsByName[row.name] ?? row
            row.requests += 1
            row.input += record.input
            row.output += record.output
            row.cacheRead += record.cacheRead
            row.cacheWrite += record.cacheWrite
            if let pricedCost { row.cost = (row.cost ?? 0) + pricedCost }
            rowsByName[row.name] = row

            let bucket = isHourly
                ? calendar.dateInterval(of: .hour, for: record.date)?.start ?? record.date
                : calendar.startOfDay(for: record.date)
            costByBucketAndName[bucket, default: [:]][row.name, default: 0] += pricedCost ?? 0
            costByName[row.name, default: 0] += pricedCost ?? 0
        }

        let totalCost = details.totals.cost
        details.rows = rowsByName.values.map { row in
            var shared = row
            shared.share = totalCost > 0 ? (row.cost ?? 0) / totalCost * 100 : 0
            return shared
        }
        details.rows = sorted(details.rows, by: .cost, ascending: false)

        // Models without cost (unpriced) draw nothing, so they are left out of the chart and its legend.
        let topNames = Set(costByName
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(visibleChartModelCount).map(\.key))
        for (bucket, costs) in costByBucketAndName {
            var otherCost = 0.0
            var hasOther = false
            for (name, cost) in costs where cost > 0 {
                if topNames.contains(name) {
                    details.chartPoints.append(UsageChartPoint(bucketStart: bucket, name: name, cost: cost))
                } else {
                    otherCost += cost
                    hasOther = true
                }
            }
            if hasOther {
                details.chartPoints.append(
                    UsageChartPoint(bucketStart: bucket, name: UsageSummary.otherModelName, cost: otherCost))
            }
        }
        details.chartPoints.sort { $0.bucketStart != $1.bucketStart ? $0.bucketStart < $1.bucketStart : $0.name < $1.name }
        return details
    }

    /// Sorts by one column. Ties are broken by name so the order is stable.
    static func sorted(_ rows: [UsageDetailRow], by column: DetailsColumn, ascending: Bool) -> [UsageDetailRow] {
        rows.sorted { left, right in
            let order: ComparisonResult
            switch column {
            case .name: order = compare(left.name, right.name)
            case .requests: order = compare(left.requests, right.requests)
            case .input: order = compare(left.input, right.input)
            case .output: order = compare(left.output, right.output)
            case .cacheRead: order = compare(left.cacheRead, right.cacheRead)
            case .cacheWrite: order = compare(left.cacheWrite, right.cacheWrite)
            case .totalTokens: order = compare(left.totalTokens, right.totalTokens)
            case .cost: order = compare(left.costSortValue, right.costSortValue)
            case .share: order = compare(left.share, right.share)
            }
            if order == .orderedSame { return left.name < right.name }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
        left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
    }
}
