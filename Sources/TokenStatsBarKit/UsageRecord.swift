import Foundation

/// One assistant message's usage. Holds numbers, model, provider and time only, never message content.
struct UsageRecord: Equatable {
    var date: Date
    var provider: String
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var cost: Double

    var totalTokens: Int { input + output + cacheRead + cacheWrite }
}
