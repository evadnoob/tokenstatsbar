import Foundation

/// One assistant response's usage. Holds numbers, model, provider and time only, never message content.
struct UsageRecord: Equatable {
    var date: Date
    var provider: String
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    /// All cache write tokens, including the one hour part.
    var cacheWrite: Int
    /// The cost the source recorded. nil when the source records none: the cost is then priced from the price cache.
    var cost: Double?
    var source: UsageSource = .pi
    /// Identifies one response that a log writes as several lines. Nil when lines never repeat.
    var deduplicationKey: String?
    /// The part of `cacheWrite` that uses the one hour cache. The rest uses the five minute cache.
    var cacheWriteOneHour: Int = 0

    var totalTokens: Int { input + output + cacheRead + cacheWrite }

    /// Keeps one record per deduplication key, the one with the most tokens. Records without a key are all kept.
    static func deduplicated(_ records: [UsageRecord]) -> [UsageRecord] {
        var result: [UsageRecord] = []
        var indexByKey: [String: Int] = [:]
        for record in records {
            guard let key = record.deduplicationKey else { result.append(record); continue }
            if let index = indexByKey[key] {
                if record.totalTokens > result[index].totalTokens { result[index] = record }
            } else {
                indexByKey[key] = result.count
                result.append(record)
            }
        }
        return result
    }
}
