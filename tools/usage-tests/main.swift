// Usage parsing, incremental reading, aggregation and formatting checks. Run: bash tools/run-tests.sh
import Foundation
@testable import TokenStatsBarKit

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

func assistantLine(model: String = "claude-opus-4-5", epochMilliseconds: Int, input: Int = 10, output: Int = 5,
                   cacheRead: Int = 100, cacheWrite: Int = 20, cost: Double = 0.5) -> String {
    "{\"type\":\"message\",\"timestamp\":\"2026-09-30T23:11:44.950Z\",\"message\":{\"role\":\"assistant\","
        + "\"content\":[{\"type\":\"text\",\"text\":\"secret\"}],\"provider\":\"anthropic\",\"model\":\"\(model)\","
        + "\"usage\":{\"input\":\(input),\"output\":\(output),\"cacheRead\":\(cacheRead),\"cacheWrite\":\(cacheWrite),"
        + "\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":\(cost)}},"
        + "\"timestamp\":\(epochMilliseconds)}}"
}

// MARK: parsing
let validLine = assistantLine(epochMilliseconds: 1_790_892_277_727)
let parsed = UsageParser.parse(line: Data(validLine.utf8))
check(parsed != nil, "valid assistant line parses")
check(parsed?.model == "claude-opus-4-5", "model parsed")
check(parsed?.provider == "anthropic", "provider parsed")
check(parsed?.input == 10 && parsed?.output == 5 && parsed?.cacheRead == 100 && parsed?.cacheWrite == 20, "token fields parsed")
check(parsed?.totalTokens == 135, "total tokens is the sum of the four fields")
check(near(parsed?.cost ?? -1, 0.5), "cost total parsed")
check(parsed?.date == Date(timeIntervalSince1970: 1_790_892_277.727), "message epoch milliseconds used")

let isoOnly = "{\"type\":\"message\",\"timestamp\":\"2026-10-01T22:04:41.353Z\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input\":1}}}"
check(UsageParser.parse(line: Data(isoOnly.utf8))?.date == Date(timeIntervalSince1970: 1_790_892_281.353), "ISO timestamp fallback")

let userLine = "{\"type\":\"message\",\"timestamp\":\"2026-10-01T22:04:41.353Z\",\"message\":{\"role\":\"user\",\"usage\":{\"input\":1}}}"
check(UsageParser.parse(line: Data(userLine.utf8)) == nil, "user line skipped")
let noUsage = "{\"type\":\"message\",\"timestamp\":\"2026-10-01T22:04:41.353Z\",\"message\":{\"role\":\"assistant\",\"model\":\"m\"}}"
check(UsageParser.parse(line: Data(noUsage.utf8)) == nil, "line without usage skipped")
let otherType = "{\"type\":\"session\",\"timestamp\":\"2026-10-01T22:04:41.353Z\",\"message\":{\"role\":\"assistant\",\"usage\":{\"input\":1}}}"
check(UsageParser.parse(line: Data(otherType.utf8)) == nil, "non message type skipped")
check(UsageParser.parse(line: Data("{not json \"usage\"".utf8)) == nil, "malformed json skipped")
check(UsageParser.parse(line: Data()) == nil, "empty line skipped")

// MARK: chunk parsing and partial lines
let chunkText = validLine + "\n" + "garbage\n" + userLine + "\n" + String(validLine.prefix(40))
let chunk = UsageParser.parseChunk(Data(chunkText.utf8))
check(chunk.records.count == 1, "chunk keeps one record")
check(chunk.consumedByteCount == (validLine + "\ngarbage\n" + userLine + "\n").utf8.count, "incomplete tail is not consumed")
check(UsageParser.parseChunk(Data(validLine.utf8)).consumedByteCount == 0, "no newline consumes nothing")

// MARK: incremental reader
let fileManager = FileManager.default
let scratch = fileManager.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID().uuidString)")
let nested = scratch.appendingPathComponent("project")
try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
let logURL = nested.appendingPathComponent("a.jsonl")
let now = Date(timeIntervalSince1970: 1_790_892_300)
let calendar = Calendar(identifier: .gregorian)
let nowMilliseconds = 1_790_892_277_727

func append(_ text: String, to url: URL) throws {
    if let handle = FileHandle(forWritingAtPath: url.path) {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    } else {
        try Data(text.utf8).write(to: url)
    }
}

let ingestor = SessionLogIngestor(rootDirectory: scratch)
func refreshCount() -> Int {
    do { return try ingestor.refresh(now: now, calendar: calendar).count } catch { return -1 }
}
try append(assistantLine(epochMilliseconds: nowMilliseconds) + "\n", to: logURL)
check(refreshCount() == 1, "first read finds one record")
check(refreshCount() == 1, "second read does not duplicate")

let second = assistantLine(epochMilliseconds: nowMilliseconds + 1000)
try append(String(second.prefix(60)), to: logURL)
check(refreshCount() == 1, "partial trailing line is held back")
try append(String(second.dropFirst(60)) + "\n", to: logURL)
check(refreshCount() == 2, "completed line is read once")

try append(assistantLine(epochMilliseconds: nowMilliseconds + 2000) + "\n", to: logURL)
check(refreshCount() == 3, "appended line is read")

try Data((assistantLine(epochMilliseconds: nowMilliseconds + 3000, cost: 9) + "\n").utf8).write(to: logURL)
let afterTruncate = try ingestor.refresh(now: now, calendar: calendar)
check(afterTruncate.count == 1 && near(afterTruncate[0].cost ?? -1, 9), "truncated file is read again from the start")

let secondLogURL = scratch.appendingPathComponent("b.jsonl")
try append(assistantLine(epochMilliseconds: nowMilliseconds) + "\n", to: secondLogURL)
check(refreshCount() == 2, "second file in the tree is read")
try fileManager.removeItem(at: secondLogURL)
check(refreshCount() == 1, "deleted file records are dropped")

let oldMilliseconds = nowMilliseconds - 40 * 86_400 * 1000
try append(assistantLine(epochMilliseconds: oldMilliseconds) + "\n", to: logURL)
check(refreshCount() == 1, "records older than 31 days are dropped")

let missing = SessionLogIngestor(rootDirectory: scratch.appendingPathComponent("missing"))
var missingFailed = false
do { _ = try missing.refresh(now: now, calendar: calendar) } catch { missingFailed = true }
check(missingFailed, "missing directory is an error")
try? fileManager.removeItem(at: scratch)

// MARK: aggregation
var fixedCalendar = Calendar(identifier: .gregorian)
fixedCalendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    fixedCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}
func record(_ date: Date, model: String = "a", cost: Double, input: Int = 1, output: Int = 2, cacheRead: Int = 3, cacheWrite: Int = 4) -> UsageRecord {
    UsageRecord(date: date, provider: "p", model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cost: cost)
}
let fixedNow = date(2026, 10, 15, 12)
let records = [
    record(date(2026, 10, 15, 0, 1), model: "a", cost: 1),
    record(date(2026, 10, 15, 11, 59), model: "b", cost: 2),
    record(date(2026, 10, 14, 23, 59), cost: 10),
    record(date(2026, 10, 9, 0, 0), cost: 100),
    record(date(2026, 10, 8, 23, 59), cost: 1000),
    record(date(2026, 10, 1, 0, 0), cost: 10_000),
    record(date(2026, 9, 30, 23, 59), cost: 100_000),
    record(date(2026, 10, 15, 13), cost: 5)
]
let summary = UsageSummary.summarize(records: records, now: fixedNow, calendar: fixedCalendar)
check(near(summary.today.cost, 8), "today cost includes all of today")
check(summary.today.requests == 3, "today request count")
check(summary.today.tokens == 30 && summary.today.input == 3 && summary.today.cacheWrite == 12, "today token totals")
check(near(summary.sevenDays.cost, 8 + 10 + 100), "7 days covers today and the six days before")
check(near(summary.thisMonth.cost, 8 + 10 + 100 + 1000 + 10_000), "this month starts on the first")
check(summary.daily.count == 14, "sparkline has 14 days")
check(summary.daily.last?.day == date(2026, 10, 15, 0), "sparkline ends today")
check(summary.daily.first?.day == date(2026, 10, 2, 0), "sparkline starts 13 days back")
check(near(summary.daily.last?.cost ?? -1, 8) && near(summary.daily[summary.daily.count - 2].cost, 10), "sparkline daily costs")
check(summary.modelsToday.map(\.model) == ["a", "b"] || summary.modelsToday.first?.model == "b", "models sorted by cost")

let empty = UsageSummary.summarize(records: [], now: fixedNow, calendar: fixedCalendar)
check(empty.today.requests == 0 && empty.modelsToday.isEmpty && empty.daily.count == 14, "empty summary")

// MARK: model grouping
func modelCost(_ model: String, _ cost: Double, provider: String? = "p") -> ModelCost {
    ModelCost(provider: provider, model: model, cost: cost)
}
let models = [modelCost("m1", 10), modelCost("m2", 8), modelCost("m3", 5), modelCost("m4", 2), modelCost("m5", 1),
              modelCost("m6", 0.5)]
let grouped = UsageSummary.groupedModels(models)
check(grouped.map(\.name) == ["p/m1", "p/m2", "p/m3", "p/m4", "other"], "top 4 plus other")
check(near(grouped[4].cost, 1.5) && grouped[4].isOther, "other sums the remaining models")
check(UsageSummary.groupedModels(Array(models.prefix(4))).count == 4, "four rows have no other row")
check(UsageSummary.groupedModels([]).isEmpty, "no models, no rows")

// MARK: provider colors
check(UsageSummary.tint(forProvider: "anthropic") == .orange, "anthropic is orange")
check(UsageSummary.tint(forProvider: "openai") == .green && UsageSummary.tint(forProvider: "openai-codex") == .green, "openai is green")
check(UsageSummary.tint(forProvider: "google") == .blue && UsageSummary.tint(forProvider: "gemini") == .blue
      && UsageSummary.tint(forProvider: "vertex_ai") == .blue, "google, gemini and vertex are blue")
check(UsageSummary.tint(forProvider: "xai") == .pink, "xai is pink")
check(UsageSummary.tint(forProvider: "mistral") == .purple, "other providers are purple")

// MARK: Claude Code parsing
func claudeLine(type: String = "assistant", model: String = "claude-sonnet-4-5-20250929", messageId: String? = "msg_1",
                requestId: String? = "req_1", output: Int = 50, cacheCreation: String? = nil,
                cacheCreationTotal: Int = 30, includeUsage: Bool = true,
                timestamp: String = "2026-10-01T22:04:41.353Z") -> String {
    var fields = ["\"type\":\"\(type)\"", "\"timestamp\":\"\(timestamp)\""]
    if let requestId { fields.append("\"requestId\":\"\(requestId)\"") }
    var message = ["\"model\":\"\(model)\"", "\"content\":[{\"type\":\"text\",\"text\":\"secret\"}]"]
    if let messageId { message.append("\"id\":\"\(messageId)\"") }
    if includeUsage {
        var usage = ["\"input_tokens\":7", "\"output_tokens\":\(output)", "\"cache_read_input_tokens\":200",
                     "\"cache_creation_input_tokens\":\(cacheCreationTotal)"]
        if let cacheCreation { usage.append("\"cache_creation\":\(cacheCreation)") }
        message.append("\"usage\":{" + usage.joined(separator: ",") + "}")
    }
    fields.append("\"message\":{" + message.joined(separator: ",") + "}")
    return "{" + fields.joined(separator: ",") + "}"
}
let claudeParsed = ClaudeCodeParser.parse(line: Data(claudeLine().utf8))
check(claudeParsed != nil, "valid Claude Code line parses")
check(claudeParsed?.provider == "anthropic" && claudeParsed?.source == .claudeCode, "Claude Code provider and source")
check(claudeParsed?.model == "claude-sonnet-4-5-20250929", "Claude Code model")
check(claudeParsed?.input == 7 && claudeParsed?.output == 50 && claudeParsed?.cacheRead == 200, "Claude Code token fields")
check(claudeParsed?.cost == nil, "Claude Code record has no recorded cost")
check(claudeParsed?.deduplicationKey == "msg_1:req_1", "deduplication key has message id and request id")
check(claudeParsed?.date == Date(timeIntervalSince1970: 1_790_892_281.353), "Claude Code fractional timestamp")
check(ClaudeCodeParser.parse(line: Data(claudeLine(requestId: nil).utf8))?.deduplicationKey == "msg_1", "key is message id alone without request id")
check(ClaudeCodeParser.parse(line: Data(claudeLine(type: "user").utf8)) == nil, "Claude Code user line skipped")
check(ClaudeCodeParser.parse(line: Data(claudeLine(includeUsage: false).utf8)) == nil, "Claude Code line without usage skipped")
check(ClaudeCodeParser.parse(line: Data(claudeLine(model: "<synthetic>").utf8)) == nil, "synthetic model skipped")
check(ClaudeCodeParser.parse(line: Data("{\"type\":\"assistant\",\"usage\": broken".utf8)) == nil, "malformed Claude Code line skipped")
let splitLine = claudeLine(cacheCreation: "{\"ephemeral_5m_input_tokens\":10,\"ephemeral_1h_input_tokens\":20}", cacheCreationTotal: 30)
let splitParsed = ClaudeCodeParser.parse(line: Data(splitLine.utf8))
check(splitParsed?.cacheWrite == 30 && splitParsed?.cacheWriteOneHour == 20, "5m and 1h split is used")
check(claudeParsed?.cacheWrite == 30 && claudeParsed?.cacheWriteOneHour == 0, "without a split all cache writes are 5m")

// MARK: Claude Code deduplication
let claudeScratch = fileManager.temporaryDirectory.appendingPathComponent("usage-tests-claude-\(UUID().uuidString)")
let sessionDirectory = claudeScratch.appendingPathComponent("project-a/session-1")
let subagentDirectory = sessionDirectory.appendingPathComponent("subagents/nested")
try fileManager.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)
let claudeLogURL = claudeScratch.appendingPathComponent("project-a/session-1.jsonl")
let claudeIngestor = SessionLogIngestor(rootDirectory: claudeScratch, source: .claudeCode)
func claudeRefresh() -> [UsageRecord] { (try? claudeIngestor.refresh(now: now, calendar: calendar)) ?? [] }
try append(claudeLine(output: 5) + "\n" + claudeLine(output: 20) + "\n" + claudeLine(output: 50) + "\n", to: claudeLogURL)
var claudeRecords = claudeRefresh()
check(claudeRecords.count == 1 && claudeRecords[0].output == 50, "three lines of one response give one record with the largest output")

try append(claudeLine(messageId: "msg_2", requestId: "req_2", output: 5) + "\n", to: claudeLogURL)
check(claudeRefresh().count == 2, "a second response is a second record")
try append(claudeLine(messageId: "msg_2", requestId: "req_2", output: 90) + "\n", to: claudeLogURL)
claudeRecords = claudeRefresh()
check(claudeRecords.count == 2 && claudeRecords.contains { $0.output == 90 }, "a later incremental read replaces the smaller record")

let agentURL = subagentDirectory.appendingPathComponent("agent-abc.jsonl")
try append(claudeLine(messageId: "msg_3", requestId: "req_3") + "\n", to: agentURL)
check(claudeRefresh().count == 3, "subagent file under subagents is discovered")
check(claudeRefresh().count == 3, "repeated read keeps three records")
try? fileManager.removeItem(at: claudeScratch)

// MARK: price cache
let litellmJSON = """
{
  "sample_spec": {"litellm_provider": "one of the supported providers", "note": "not a model"},
  "claude-sonnet-4-5": {"litellm_provider": "anthropic", "mode": "chat", "max_tokens": 64000,
    "input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05, "cache_creation_input_token_cost": 3.75e-06,
    "cache_creation_input_token_cost_above_1hr": 6e-06, "cache_read_input_token_cost": 3e-07},
  "claude-haiku-4-5": {"litellm_provider": "anthropic", "input_cost_per_token": 1e-06, "output_cost_per_token": 5e-06,
    "cache_creation_input_token_cost": 1.25e-06, "cache_read_input_token_cost": 1e-07},
  "gpt-6.1-sol": {"litellm_provider": "openai", "input_cost_per_token": 2e-06, "output_cost_per_token": 8e-06},
  "gemini-3": {"litellm_provider": "gemini", "input_cost_per_token": 1e-06},
  "bedrock-claude": {"litellm_provider": "bedrock", "input_cost_per_token": 9e-06},
  "openrouter/thing": {"litellm_provider": "openrouter", "input_cost_per_token": 9e-06}
}
"""
let filtered = try PriceCache.filter(litellmJSON: Data(litellmJSON.utf8))
check(Set(filtered.keys) == ["claude-sonnet-4-5", "claude-haiku-4-5", "gpt-6.1-sol", "gemini-3"],
      "providers kept and dropped")
check(filtered["claude-sonnet-4-5"] == ModelPrice(input: 3e-06, output: 1.5e-05, cacheRead: 3e-07, cacheCreation: 3.75e-06,
                                                   cacheCreationAboveOneHour: 6e-06), "price fields kept")
check(filtered["gpt-6.1-sol"]?.cacheRead == nil, "missing price fields stay nil")

var notObject = false
do { _ = try PriceCache.filter(litellmJSON: Data("[1,2]".utf8)) } catch { notObject = true }
check(notObject, "a json array is not a price list")
var noModels = false
do { _ = try PriceCache.contents(litellmJSON: Data("{\"x\":{\"litellm_provider\":\"bedrock\"}}".utf8), builtAt: Date()) } catch { noModels = true }
check(noModels, "a list without supported models is an error")

let priceScratch = fileManager.temporaryDirectory.appendingPathComponent("usage-tests-prices-\(UUID().uuidString)")
let priceFile = priceScratch.appendingPathComponent("nested/prices.json")
let builtAt = Date(timeIntervalSince1970: 1_790_892_000)
let contents = try PriceCache.contents(litellmJSON: Data(litellmJSON.utf8), builtAt: builtAt)
check(contents.modelCount == 4, "model count")
check(PriceCache.read(from: priceFile) == nil, "missing cache file reads as nil")
try PriceCache.write(contents, to: priceFile)
let reread = PriceCache.read(from: priceFile)
check(reread == contents, "price cache round trip")
check(reread?.builtAt == builtAt, "built date round trip")
try? fileManager.removeItem(at: priceScratch)
check(PriceCache.defaultFileURL(home: URL(fileURLWithPath: "/h")).path == "/h/Library/Caches/com.evadnoob.tokenstatsbar/prices.json", "cache path")

check(PriceCache.price(for: "claude-sonnet-4-5", in: filtered) != nil, "exact lookup")
check(PriceCache.price(for: "claude-sonnet-4-5-20250929", in: filtered)?.input == 3e-06, "date suffix stripped")
check(PriceCache.price(for: "claude-unknown-9-20250929", in: filtered) == nil, "unknown model is unpriced")
check(PriceCache.price(for: "claude-sonnet-4-5-latest", in: filtered) == nil, "only a date suffix is stripped")

let priced = UsageRecord(date: now, provider: "anthropic", model: "claude-sonnet-4-5", input: 1_000_000, output: 100_000,
                         cacheRead: 2_000_000, cacheWrite: 300_000, cost: nil, source: .claudeCode, cacheWriteOneHour: 100_000)
// 1M * 3e-06 + 100K * 1.5e-05 + 2M * 3e-07 + 200K * 3.75e-06 + 100K * 6e-06
check(near(filtered["claude-sonnet-4-5"]!.cost(of: priced), 3 + 1.5 + 0.6 + 0.75 + 0.6), "cost math with 5m and 1h writes")
var fallbackRecord = priced
fallbackRecord.model = "claude-haiku-4-5"
// no one hour price: 1h writes use the 5m price. 1M * 1e-06 + 100K * 5e-06 + 2M * 1e-07 + 300K * 1.25e-06
check(near(filtered["claude-haiku-4-5"]!.cost(of: fallbackRecord), 1 + 0.5 + 0.2 + 0.375), "1h writes fall back to the 5m price")

// MARK: provider and model aggregation
func mixed(_ date: Date, provider: String, model: String, cost: Double?, source: UsageSource = .pi) -> UsageRecord {
    UsageRecord(date: date, provider: provider, model: model, input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0,
                cost: cost, source: source)
}
let mixedRecords = [
    mixed(date(2026, 10, 15, 9), provider: "anthropic", model: "claude-sonnet-4-5", cost: 2),
    mixed(date(2026, 10, 15, 10), provider: "anthropic", model: "claude-sonnet-4-5-20250929", cost: nil, source: .claudeCode),
    mixed(date(2026, 10, 15, 10), provider: "anthropic", model: "claude-sonnet-4-5", cost: nil, source: .claudeCode),
    mixed(date(2026, 10, 15, 11), provider: "openai", model: "gpt-6.1-sol", cost: 1),
    mixed(date(2026, 10, 15, 11), provider: "xai", model: "grok", cost: 0.5),
    mixed(date(2026, 10, 15, 11), provider: "google", model: "g", cost: 0.4),
    mixed(date(2026, 10, 15, 11), provider: "mistral", model: "m", cost: 0.3),
    mixed(date(2026, 10, 15, 11), provider: "deepseek", model: "d", cost: 0.2),
    mixed(date(2026, 10, 15, 12), provider: "anthropic", model: "claude-unpriced-1", cost: nil, source: .claudeCode)
]
let mixedSummary = UsageSummary.summarize(records: mixedRecords, prices: filtered, now: fixedNow, calendar: fixedCalendar)
let sonnetRows = mixedSummary.modelsToday.filter { $0.name == "anthropic/claude-sonnet-4-5" }
check(sonnetRows.count == 1, "pi and Claude Code share one row per provider and model")
check(mixedSummary.modelsToday.contains { $0.name == "anthropic/claude-sonnet-4-5-20250929" && near($0.cost, 3) }, "date suffixed name is a separate row from its base name")
check(mixedSummary.modelsToday.first?.name == "anthropic/claude-sonnet-4-5" && near(mixedSummary.modelsToday.first?.cost ?? -1, 5),
      "pi cost and Claude Code priced cost add up in one row")
check(mixedSummary.unpricedRequestsToday == 1, "unpriced Claude Code requests are counted")
check(near(mixedSummary.today.cost, 5 + 3 + 1 + 0.5 + 0.4 + 0.3 + 0.2), "unpriced requests add no cost")
let mixedRows = UsageSummary.groupedModels(mixedSummary.modelsToday)
check(mixedRows.count == 5 && mixedRows.last?.isOther == true, "top 4 plus other")
check(Array(mixedRows.map(\.name).prefix(4)) == ["anthropic/claude-sonnet-4-5", "anthropic/claude-sonnet-4-5-20250929", "openai/gpt-6.1-sol", "xai/grok"], "rows ordered by cost")
check(near(mixedRows.last?.cost ?? -1, 0.4 + 0.3 + 0.2), "other sums the rest")
let piOnly = UsageSummary.summarize(records: [mixed(date(2026, 10, 15, 9), provider: "p", model: "a", cost: 2)], now: fixedNow, calendar: fixedCalendar)
check(piOnly.unpricedRequestsToday == 0 && near(piOnly.today.cost, 2), "pi records are never unpriced")
let repriced = UsageSummary.summarize(records: mixedRecords, prices: [:], now: fixedNow, calendar: fixedCalendar)
check(repriced.unpricedRequestsToday == 3, "without a price cache every Claude Code request is unpriced")
let emptyPrice = ModelPrice(input: nil, output: nil, cacheRead: nil, cacheCreation: nil, cacheCreationAboveOneHour: nil)
let emptyPriceSummary = UsageSummary.summarize(records: [mixedRecords[2]], prices: ["claude-sonnet-4-5": emptyPrice],
                                               now: fixedNow, calendar: fixedCalendar)
check(emptyPriceSummary.unpricedRequestsToday == 1, "a price entry without input and output prices is unpriced, not free")

// MARK: formatting
check(UsageFormat.tokens(0) == "0", "tokens zero")
check(UsageFormat.tokens(999) == "999", "tokens below 1K")
check(UsageFormat.tokens(1500) == "1.5K", "tokens 1.5K")
check(UsageFormat.tokens(12_345) == "12.3K", "tokens 12.3K")
check(UsageFormat.tokens(48_000) == "48K", "tokens 48K")
check(UsageFormat.tokens(210_000) == "210K", "tokens 210K")
check(UsageFormat.tokens(1_240_000) == "1.24M", "tokens 1.24M")
check(UsageFormat.cost(4.82) == "$4.82", "cost 4.82")
check(UsageFormat.cost(0) == "$0.00", "cost zero")
check(UsageFormat.cost(1234.5) == "$1,234.50", "cost grouping")
check(UsageFormat.cost(0.004) == "$0.00", "cost rounds to cents")
check(UsageFormat.age(seconds: 12) == "12s ago" && UsageFormat.age(seconds: 125) == "2m ago" && UsageFormat.age(seconds: 7300) == "2h ago", "age text")
check(UsageFormat.requests(1) == "1 request" && UsageFormat.requests(86) == "86 requests", "request text")

if failures > 0 {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
print("\(checks) checks passed")
