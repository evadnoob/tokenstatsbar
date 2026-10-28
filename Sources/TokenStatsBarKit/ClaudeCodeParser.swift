import Foundation

/// Pure parsing of Claude Code transcript lines. Only the numeric usage fields, model, identifiers and timestamp
/// are decoded, so message content is never read into a model value.
/// The format is not documented by Anthropic. See https://github.com/dutchdata/claude-transcript/blob/main/FORMAT.md
enum ClaudeCodeParser {
    private struct Line: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                struct CacheCreation: Decodable {
                    var fiveMinutes: Double?
                    var oneHour: Double?
                    enum CodingKeys: String, CodingKey {
                        case fiveMinutes = "ephemeral_5m_input_tokens"
                        case oneHour = "ephemeral_1h_input_tokens"
                    }
                }
                var input: Double?
                var output: Double?
                var cacheRead: Double?
                var cacheCreationTotal: Double?
                var cacheCreation: CacheCreation?
                enum CodingKeys: String, CodingKey {
                    case input = "input_tokens"
                    case output = "output_tokens"
                    case cacheRead = "cache_read_input_tokens"
                    case cacheCreationTotal = "cache_creation_input_tokens"
                    case cacheCreation = "cache_creation"
                }
            }
            var id: String?
            var model: String?
            var usage: Usage?
        }
        var type: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    static let syntheticModel = "<synthetic>"
    static let providerName = "anthropic"
    private static let usageMarker = Data("\"usage\"".utf8)
    // Parsing runs on one serial queue, so a shared decoder is safe.
    private static let decoder = JSONDecoder()

    /// Returns a record for an assistant line with usage, or nil for anything else, including malformed json
    /// and the synthetic messages that Claude Code writes without calling a model.
    static func parse(line: Data) -> UsageRecord? {
        guard line.range(of: usageMarker) != nil,
              let decoded = try? decoder.decode(Line.self, from: line),
              decoded.type == "assistant",
              let message = decoded.message,
              let usage = message.usage,
              let model = message.model, model != syntheticModel,
              let timestamp = decoded.timestamp,
              let date = UsageParser.date(fromISO: timestamp) else { return nil }

        let cacheWrite: Int
        let oneHour: Int
        if let split = usage.cacheCreation, split.fiveMinutes != nil || split.oneHour != nil {
            oneHour = Int(split.oneHour ?? 0)
            cacheWrite = Int(split.fiveMinutes ?? 0) + oneHour
        } else {
            cacheWrite = Int(usage.cacheCreationTotal ?? 0)
            oneHour = 0
        }
        var key: String?
        if let messageId = message.id {
            key = decoded.requestId.map { "\(messageId):\($0)" } ?? messageId
        }
        return UsageRecord(
            date: date,
            provider: providerName,
            model: model,
            input: Int(usage.input ?? 0),
            output: Int(usage.output ?? 0),
            cacheRead: Int(usage.cacheRead ?? 0),
            cacheWrite: cacheWrite,
            cost: nil,
            source: .claudeCode,
            deduplicationKey: key,
            cacheWriteOneHour: oneHour)
    }
}
