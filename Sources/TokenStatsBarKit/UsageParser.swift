import Foundation

/// Pure parsing of pi session log lines. Only the numeric usage fields, model, provider and timestamp are decoded,
/// so message content is never read into a model value.
enum UsageParser {
    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct Cost: Decodable {
                    var input: Double?
                    var output: Double?
                    var cacheRead: Double?
                    var cacheWrite: Double?
                    var total: Double?
                }
                var input: Double?
                var output: Double?
                var cacheRead: Double?
                var cacheWrite: Double?
                var cost: Cost?
            }
            var role: String?
            var provider: String?
            var model: String?
            var timestamp: Double?
            var usage: Usage?
        }
        var type: String?
        var timestamp: String?
        var message: Message?
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    /// Returns a record for an assistant message line with usage, or nil for anything else, including malformed json.
    /// The message epoch milliseconds are preferred; the top level ISO 8601 timestamp is the fallback.
    static func parse(line: Data) -> UsageRecord? {
        guard line.range(of: usageMarker) != nil,
              let decoded = try? JSONDecoder().decode(Line.self, from: line),
              decoded.type == "message",
              let message = decoded.message,
              message.role == "assistant",
              let usage = message.usage,
              let date = timestamp(epochMilliseconds: message.timestamp, iso: decoded.timestamp) else { return nil }
        let cost = usage.cost
        let componentCost = (cost?.input ?? 0) + (cost?.output ?? 0) + (cost?.cacheRead ?? 0) + (cost?.cacheWrite ?? 0)
        return UsageRecord(
            date: date,
            provider: message.provider ?? "unknown",
            model: message.model ?? "unknown",
            input: Int(usage.input ?? 0),
            output: Int(usage.output ?? 0),
            cacheRead: Int(usage.cacheRead ?? 0),
            cacheWrite: Int(usage.cacheWrite ?? 0),
            cost: cost?.total ?? componentCost)
    }

    /// Parses every complete (newline terminated) line in the data. `consumedByteCount` stops after the last
    /// newline, so an incomplete trailing line is left for the next read.
    static func parseChunk(_ data: Data, source: UsageSource = .pi) -> (records: [UsageRecord], consumedByteCount: Int) {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let complete = data[data.startIndex..<lastNewline]
        var records: [UsageRecord] = []
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let record = source.parse(line: Data(line)) { records.append(record) }
        }
        return (records, data.distance(from: data.startIndex, to: lastNewline) + 1)
    }

    private static func timestamp(epochMilliseconds: Double?, iso: String?) -> Date? {
        if let epochMilliseconds { return Date(timeIntervalSince1970: epochMilliseconds / 1000) }
        guard let iso else { return nil }
        return date(fromISO: iso)
    }

    /// ISO 8601 with or without fractional seconds.
    static func date(fromISO iso: String) -> Date? {
        fractionalSecondsFormatter.date(from: iso) ?? wholeSecondsFormatter.date(from: iso)
    }

    // ISO8601DateFormatter is thread safe, so the formatters are shared instead of built per line.
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
