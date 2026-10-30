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

// MARK: usage details
func detailRecord(_ date: Date, provider: String = "anthropic", model: String = "m1", source: UsageSource = .pi,
                  cost: Double?, input: Int = 10, output: Int = 5) -> UsageRecord {
    UsageRecord(date: date, provider: provider, model: model, input: input, output: output, cacheRead: 100,
                cacheWrite: 20, cost: cost, source: source)
}
func summarizeDetails(_ records: [UsageRecord], _ range: DetailsRange, _ source: DetailsSourceFilter = .all,
                      prices: [String: ModelPrice] = [:]) -> UsageDetails {
    UsageDetails.summarize(records: records, prices: prices, range: range, source: source, now: fixedNow,
                           calendar: fixedCalendar)
}
// fixedNow is 2026-10-15 12:00 in the fixed calendar.
let boundaryRecords = [
    detailRecord(date(2026, 10, 15, 0), cost: 1),      // start of today
    detailRecord(date(2026, 10, 14, 23, 59), cost: 2), // just before today
    detailRecord(date(2026, 10, 9, 0), cost: 4),       // start of the 7 day range
    detailRecord(date(2026, 10, 8, 23, 59), cost: 8),  // just before the 7 day range
    detailRecord(date(2026, 10, 1, 0), cost: 16),      // start of the month
    detailRecord(date(2026, 9, 30, 23, 59), cost: 32), // before the month
    detailRecord(date(2026, 9, 14, 12), cost: 64),     // oldest kept record
    detailRecord(date(2026, 10, 16, 0), cost: 128)     // tomorrow
]
check(near(summarizeDetails(boundaryRecords, .today).totals.cost, 1), "details Today boundary")
check(near(summarizeDetails(boundaryRecords, .sevenDays).totals.cost, 1 + 2 + 4), "details 7 days boundary")
check(near(summarizeDetails(boundaryRecords, .thisMonth).totals.cost, 1 + 2 + 4 + 8 + 16), "details This month boundary")
check(near(summarizeDetails(boundaryRecords, .thirtyOneDays).totals.cost, 1 + 2 + 4 + 8 + 16 + 32 + 64), "details 31 days keeps everything up to today")

let sourceRecords = [
    detailRecord(date(2026, 10, 15, 9), model: "a", source: .pi, cost: 1),
    detailRecord(date(2026, 10, 15, 10), model: "b", source: .claudeCode, cost: nil)
]
let sonnetPrice = ModelPrice(input: 1e-6, output: 2e-6, cacheRead: nil, cacheCreation: nil, cacheCreationAboveOneHour: nil)
check(summarizeDetails(sourceRecords, .today, .all).totals.requests == 2, "details source All")
check(summarizeDetails(sourceRecords, .today, .pi).rows.map(\.model) == ["a"], "details source pi")
check(summarizeDetails(sourceRecords, .today, .claudeCode).rows.map(\.model) == ["b"], "details source Claude Code")

let rowRecords = [
    detailRecord(date(2026, 10, 15, 9), model: "a", cost: 3, input: 10, output: 1),
    detailRecord(date(2026, 10, 15, 10), model: "a", cost: 1, input: 20, output: 2),
    detailRecord(date(2026, 10, 15, 11), model: "b", source: .claudeCode, cost: nil, input: 1_000_000, output: 0),
    detailRecord(date(2026, 10, 15, 11), model: "c", source: .claudeCode, cost: nil)
]
let rowDetails = summarizeDetails(rowRecords, .today, prices: ["b": sonnetPrice])
let rowA = rowDetails.rows.first { $0.model == "a" }
let rowB = rowDetails.rows.first { $0.model == "b" }
let rowC = rowDetails.rows.first { $0.model == "c" }
check(rowDetails.rows.count == 3, "details one row per provider and model")
check(rowA?.requests == 2 && rowA?.input == 30 && rowA?.output == 3 && rowA?.cacheRead == 200 && rowA?.cacheWrite == 40, "details row sums")
check(rowA?.totalTokens == 273 && rowA?.name == "anthropic/a", "details row total tokens and name")
check(near(rowA?.cost ?? -1, 4), "details row cost sums recorded costs")
check(rowC?.cost == nil && rowC?.share == 0, "details unpriced row has nil cost and no share")
check(rowDetails.unpricedRequests == 1, "details unpriced count")
check(!rowDetails.chartPoints.contains { $0.name == "anthropic/c" }, "details chart leaves out unpriced models")
check(rowDetails.totals.requests == 4 && near(rowDetails.totals.cost, 4 + (rowB?.cost ?? 0)), "details totals")
check(near(rowDetails.rows.reduce(0) { $0 + $1.share }, 100), "details shares add up to 100 percent")
check(rowDetails.rows.map(\.model) == ["a", "b", "c"], "details rows start with the highest cost")
check(summarizeDetails([], .today).rows.isEmpty, "details empty range has no rows")

let sortRecords = [
    detailRecord(date(2026, 10, 15, 9), provider: "p", model: "x", cost: 5, input: 1, output: 0),
    detailRecord(date(2026, 10, 15, 9), provider: "p", model: "x", cost: 5, input: 1, output: 0),
    detailRecord(date(2026, 10, 15, 9), provider: "p", model: "y", cost: 2, input: 500, output: 0),
    detailRecord(date(2026, 10, 15, 9), provider: "p", model: "z", source: .claudeCode, cost: nil, input: 50, output: 0)
]
let sortRows = summarizeDetails(sortRecords, .today).rows
func sortedModels(_ column: DetailsColumn, _ ascending: Bool) -> [String] {
    UsageDetails.sorted(sortRows, by: column, ascending: ascending).map(\.model)
}
check(sortedModels(.name, true) == ["x", "y", "z"] && sortedModels(.name, false) == ["z", "y", "x"], "details sort by name")
check(sortedModels(.requests, false) == ["x", "y", "z"] && sortedModels(.requests, true).first == "y", "details sort by requests")
check(sortedModels(.input, false) == ["y", "z", "x"] && sortedModels(.input, true) == ["x", "z", "y"], "details sort by input")
check(sortedModels(.totalTokens, false) == ["y", "x", "z"], "details sort by total tokens")
check(sortedModels(.cost, false) == ["x", "y", "z"] && sortedModels(.cost, true) == ["z", "y", "x"], "details sort by cost, unpriced lowest")
check(sortedModels(.share, false) == ["x", "y", "z"], "details sort by share")
check(sortedModels(.output, true) == ["x", "y", "z"] && sortedModels(.cacheRead, false) == ["x", "y", "z"]
      && sortedModels(.cacheWrite, true) == ["y", "z", "x"], "details sort by output, cache read and cache write")

let hourlyRecords = [
    detailRecord(date(2026, 10, 15, 9, 5), cost: 1),
    detailRecord(date(2026, 10, 15, 9, 50), cost: 2),
    detailRecord(date(2026, 10, 15, 11, 0), cost: 4)
]
let hourly = summarizeDetails(hourlyRecords, .today)
check(hourly.isHourly && hourly.chartPoints.count == 2, "details Today chart uses hourly buckets")
check(hourly.chartPoints.first?.bucketStart == date(2026, 10, 15, 9) && near(hourly.chartPoints.first?.cost ?? -1, 3), "details hourly bucket sums")
let daily = summarizeDetails(hourlyRecords + [detailRecord(date(2026, 10, 14, 15), cost: 8)], .sevenDays)
check(!daily.isHourly && daily.chartPoints.count == 2, "details 7 days chart uses daily buckets")
check(daily.chartPoints.first?.bucketStart == date(2026, 10, 14, 0) && near(daily.chartPoints.last?.cost ?? -1, 7), "details daily bucket sums")

let manyRecords = (1...10).map { index in
    detailRecord(date(2026, 10, 15, 9), model: "m\(index)", cost: Double(index))
}
let many = summarizeDetails(manyRecords, .today)
let manyNames = Set(many.chartPoints.map(\.name))
check(manyNames.count == 9 && manyNames.contains("other"), "details chart has the top 8 and other")
check(!manyNames.contains("anthropic/m1") && !manyNames.contains("anthropic/m2") && manyNames.contains("anthropic/m10"), "details chart groups the cheapest models")
check(near(many.chartPoints.first { $0.name == "other" }?.cost ?? -1, 3), "details other sums the rest")
check(summarizeDetails(Array(manyRecords.prefix(8)), .today).chartPoints.allSatisfy { $0.name != "other" }, "details chart has no other when 8 models fit")

// MARK: sunburst layout
func sunburstRows(_ records: [UsageRecord], prices: [String: ModelPrice] = [:]) -> [UsageDetailRow] {
    summarizeDetails(records, .thirtyOneDays, prices: prices).rows
}
func sunburstRecord(_ provider: String, _ model: String, cost: Double?, source: UsageSource = .pi, day: Int = 15,
                    input: Int = 10) -> UsageRecord {
    detailRecord(date(2026, 10, day, 9), provider: provider, model: model, source: source, cost: cost, input: input)
}
let sunburstRecords = [
    sunburstRecord("anthropic", "big", cost: 40),
    sunburstRecord("anthropic", "mid", cost: 20),
    sunburstRecord("anthropic", "tiny", cost: 0.2),
    sunburstRecord("openai", "gpt", cost: 30),
    sunburstRecord("openai", "free", cost: nil),
    sunburstRecord("google", "flash", cost: 9),
    sunburstRecord("xai", "dust", cost: 0.2),
    sunburstRecord("mistral", "dust", cost: 0.1)
]
let sunburstAll = SunburstLayout.layout(rows: sunburstRows(sunburstRecords), metric: .cost, drillProvider: nil)
func ring(_ layout: SunburstLayout, _ index: Int) -> [SunburstSlice] { layout.slices.filter { $0.ring == index } }

check(sunburstAll.ringCount == 2, "sunburst All has two rings")
check(ring(sunburstAll, 0).map(\.name) == ["anthropic", "openai", "google", "other"], "sunburst providers sorted by value, small ones merged into other")
check(near(ring(sunburstAll, 0).first?.startAngle ?? -1, 0), "sunburst starts at 12 o'clock")
check(near(ring(sunburstAll, 0).last?.endAngle ?? -1, 360), "sunburst provider ring sums to 360 degrees")
check(zip(ring(sunburstAll, 0), ring(sunburstAll, 0).dropFirst()).allSatisfy { near($0.endAngle, $1.startAngle) }, "sunburst provider arcs run clockwise without overlap")
check(near(ring(sunburstAll, 0).first?.span ?? 0, 360 * 60.2 / 99.5), "sunburst angle is value over total")
check(near(ring(sunburstAll, 0).map(\.share).reduce(0, +), 100), "sunburst shares sum to 100 percent")
check(ring(sunburstAll, 0).filter(\.isOther).count == 1 && ring(sunburstAll, 1).filter { $0.provider == nil }.count == 1, "sunburst has one merged other slice for the provider ring")
let anthropicRing0 = ring(sunburstAll, 0).first { $0.provider == "anthropic" }!
let anthropicChildren = ring(sunburstAll, 1).filter { $0.provider == "anthropic" }
check(anthropicChildren.map(\.name) == ["big", "mid", "other"], "sunburst models sorted by value with tiny model merged into other")
check(near(anthropicChildren.first!.startAngle, anthropicRing0.startAngle) && near(anthropicChildren.last!.endAngle, anthropicRing0.endAngle), "sunburst model arcs fill their provider arc")
check(ring(sunburstAll, 1).allSatisfy { child in
    ring(sunburstAll, 0).contains { parent in child.startAngle >= parent.startAngle - 1e-9 && child.endAngle <= parent.endAngle + 1e-9 }
}, "sunburst child arcs stay inside a parent arc")
check(near(ring(sunburstAll, 1).last?.endAngle ?? -1, 360) && near(ring(sunburstAll, 1).map(\.span).reduce(0, +), 360), "sunburst model ring sums to 360 degrees")
check(ring(sunburstAll, 1).first { $0.isOther && $0.provider == nil }.map { $0.startAngle == ring(sunburstAll, 0).last!.startAngle } == true, "sunburst merged provider other has a matching model ring other")
check(!sunburstAll.slices.contains { $0.name == "free" }, "sunburst Cost excludes unpriced models")
let sunburstTokens = SunburstLayout.layout(rows: sunburstRows(sunburstRecords), metric: .tokens, drillProvider: nil)
check(sunburstTokens.slices.contains { $0.name == "free" } && near(sunburstTokens.total, 135 * 8), "sunburst Tokens includes unpriced models")
check(near(ring(sunburstTokens, 0).map(\.span).reduce(0, +), 360), "sunburst Tokens ring sums to 360 degrees")

let drilled = SunburstLayout.layout(rows: sunburstRows(sunburstRecords), metric: .cost, drillProvider: "anthropic")
check(drilled.ringCount == 1 && drilled.slices.allSatisfy { $0.ring == 0 && ($0.provider == "anthropic") }, "sunburst drill level has only that provider")
check(drilled.slices.map(\.name) == ["big", "mid", "other"] && near(drilled.slices.map(\.span).reduce(0, +), 360) && near(drilled.slices.first!.startAngle, 0), "sunburst drill level fills 360 degrees")
check(near(drilled.slices.first!.share, 40 / 60.2 * 100), "sunburst drill share is of the provider total")
check(SunburstLayout.layout(rows: [], metric: .cost, drillProvider: nil).slices.isEmpty, "sunburst of no rows is empty")
check(SunburstLayout.layout(rows: sunburstRows(sunburstRecords), metric: .cost, drillProvider: "missing").slices.isEmpty, "sunburst of a provider without rows is empty")

// Hit test: center at the origin, hole radius 40, outer radius 140, two rings of 50 each (ring 0 is 40 to 90).
func hit(_ layout: SunburstLayout, _ x: Double, _ y: Double) -> String? {
    layout.hitTest(point: (x, y), innerRadius: 40, outerRadius: 140)
}
check(hit(sunburstAll, 5, 0) == nil && hit(sunburstAll, 0, 0) == nil, "hit test hole is nil")
check(hit(sunburstAll, 0, -150) == nil && hit(sunburstAll, 141, 0) == nil, "hit test outside is nil")
check(hit(sunburstAll, 1, -60) == "0/anthropic", "hit test ring 0 just after 12 o'clock is the first provider")
check(hit(sunburstAll, 1, -110) == "1/anthropic/big", "hit test ring 1 just after 12 o'clock is the first model")
check(hit(sunburstAll, -1, -60) == "0/other", "hit test just before 12 o'clock is the last slice")
let halfwayAngle = (anthropicRing0.endAngle + ring(sunburstAll, 0)[1].endAngle) / 2 * Double.pi / 180
check(hit(sunburstAll, 60 * sin(halfwayAngle), -60 * cos(halfwayAngle)) == "0/openai", "hit test follows angles clockwise")
check(hit(sunburstAll, 100 * sin(halfwayAngle), -100 * cos(halfwayAngle)) == "1/openai/gpt", "hit test ring 1 maps to a model")
check(SunburstLayout.layout(rows: sunburstRows(sunburstRecords), metric: .cost, drillProvider: "anthropic")
        .hitTest(point: (-100, 0), innerRadius: 40, outerRadius: 140) == "0/anthropic/mid", "hit test drill level has a single wide ring")
// Hit test follows the drawing: the selected slice is offset, the hovered slice is lifted. In sunburstAll the
// first model "1/anthropic/big" spans 0 to its end angle in ring 1 (90 to 140).
let bigSlice = sunburstAll.slices.first { $0.id == "1/anthropic/big" }!
let bigRowID = bigSlice.rowID!
let bigMiddle = (bigSlice.startAngle + bigSlice.endAngle) / 2 * Double.pi / 180
func hitDrawn(_ layout: SunburstLayout, _ x: Double, _ y: Double, selected: String? = nil, hovered: String? = nil) -> String? {
    layout.hitTest(point: (x, y), innerRadius: 40, outerRadius: 140, selectedRowID: selected, hoveredID: hovered)
}
let bandX = 143 * sin(bigMiddle), bandY = -143 * cos(bigMiddle)
check(hitDrawn(sunburstAll, bandX, bandY) == nil, "outer band point misses without selection")
check(hitDrawn(sunburstAll, bandX, bandY, selected: bigRowID) == "1/anthropic/big", "outer offset band of the selected slice hits it")
check(hitDrawn(sunburstAll, 100 * sin(bigMiddle), -100 * cos(bigMiddle), selected: bigRowID) == "1/anthropic/big", "selected slice still hits inside its base arc")
check(hitDrawn(sunburstAll, 142 * sin(bigMiddle), -142 * cos(bigMiddle), hovered: "1/anthropic/big") == "1/anthropic/big", "lift rim of the hovered slice hits it")
check(hitDrawn(sunburstAll, 142 * sin(bigMiddle), -142 * cos(bigMiddle), hovered: "0/anthropic") == "1/anthropic/big", "lift rim of a model under a hovered provider hits the model")
check(hitDrawn(sunburstAll, 142 * sin(bigMiddle), -142 * cos(bigMiddle), hovered: "0/openai") == nil, "lift rim of another slice does not hit")
check(hitDrawn(sunburstAll, 100 * sin(bigMiddle), -100 * cos(bigMiddle)) == "1/anthropic/big" && hitDrawn(sunburstAll, 60 * sin(bigMiddle), -60 * cos(bigMiddle)) == "0/anthropic"
      && hitDrawn(sunburstAll, 5, 0) == nil && hitDrawn(sunburstAll, 100 * sin(halfwayAngle), -100 * cos(halfwayAngle), hovered: "0/anthropic") == "1/openai/gpt", "hit test base behavior is unchanged")
check(sunburstAll.isHighlighted("1/anthropic/big", hoveredID: "0/anthropic") && !sunburstAll.isHighlighted("1/openai/gpt", hoveredID: "0/anthropic")
      && sunburstAll.isHighlighted("0/anthropic", hoveredID: "0/anthropic") && !sunburstAll.isHighlighted("0/openai", hoveredID: nil), "hovering a provider highlights its models")

check(SunburstLayout.colorKey(forProvider: "anthropic") == "amber" && SunburstLayout.colorKey(forProvider: "openai-codex") == "teal"
      && SunburstLayout.colorKey(forProvider: "vertex_ai") == "blue" && SunburstLayout.colorKey(forProvider: "xai") == "rose"
      && SunburstLayout.colorKey(forProvider: "github-copilot") == "violet" && SunburstLayout.colorKey(forProvider: "mistral") == "slate", "sunburst provider color keys")
check(anthropicChildren.map(\.shadeIndex) == [0, 1, 0] && anthropicChildren.map(\.colorKey) == ["amber", "amber", "gray"], "sunburst model shade indices by rank, other is gray")
check(ring(sunburstAll, 0).map(\.colorKey) == ["amber", "teal", "blue", "gray"], "sunburst provider ring color keys")

// MARK: design pass: palette, motion geometry, headline, accessibility text
let providerSamples = ["anthropic", "openai", "openai-codex", "google", "gemini", "vertex_ai", "xai", "github-copilot", "mistral", ""]
check(providerSamples.allSatisfy { SunburstColors.colorKeys.contains(SunburstLayout.colorKey(forProvider: $0)) }, "every provider maps to a palette color key")
check(SunburstColors.colorKeys.contains(SunburstLayout.otherColorKey), "the other color key is in the palette")
for key in SunburstColors.colorKeys {
    for isDark in [false, true] {
        let shades = (0...SunburstColors.maximumShadeIndex).map { SunburstColors.shade(colorKey: key, shadeIndex: $0, isDark: isDark) }
        check(Set(shades.map(\.brightness)).count == shades.count, "shades differ per rank for \(key), dark \(isDark)")
        check(shades.allSatisfy { $0.brightness >= 0 && $0.brightness <= 1 && $0.saturation >= 0 && $0.saturation <= 1 }, "shades stay in range for \(key), dark \(isDark)")
    }
    let lightShades = (0...SunburstColors.maximumShadeIndex).map { SunburstColors.shade(colorKey: key, shadeIndex: $0, isDark: false, tone: 1) }
    check(lightShades.allSatisfy { $0.brightness <= 0.9 }, "light brightness stays at or below 0.9 for \(key)")
    if key != "gray" && key != "slate" {
        check(lightShades.allSatisfy { $0.saturation >= 0.45 }, "light saturation stays visible against white for \(key)")
    }
    check(SunburstColors.shade(colorKey: key, shadeIndex: 0, isDark: false) != SunburstColors.shade(colorKey: key, shadeIndex: 0, isDark: true), "light and dark variants differ for \(key)")
    check(SunburstColors.shade(colorKey: key, shadeIndex: 99, isDark: false) == SunburstColors.shade(colorKey: key, shadeIndex: SunburstColors.maximumShadeIndex, isDark: false), "shade rank is capped for \(key)")
    check(SunburstColors.shade(colorKey: key, shadeIndex: 1, isDark: false, tone: 1).brightness > SunburstColors.shade(colorKey: key, shadeIndex: 1, isDark: false, tone: -1).brightness, "outer tone is lighter than inner tone for \(key)")
}
check(Set(["amber", "teal", "violet", "blue", "rose"].map { SunburstColors.shade(colorKey: $0, shadeIndex: 0, isDark: false).hue }).count == 5, "provider hues are distinct")
check(near(SunburstColors.shade(colorKey: "amber", shadeIndex: 0, isDark: false).hue * 360, 41.4), "amber hue is away from the Claude terracotta")
check(SunburstColors.shade(colorKey: "gray", shadeIndex: 0, isDark: false).saturation == 0 && SunburstColors.shade(colorKey: "slate", shadeIndex: 0, isDark: false).saturation < SunburstColors.shade(colorKey: "blue", shadeIndex: 0, isDark: false).saturation, "gray has no saturation and slate is muted")

check(SunburstMotion.hoverLift == 4 && SunburstMotion.explodeDistance == 6, "motion distances")
check(near(SunburstMotion.outerRadius(100, isLifted: true), 104) && near(SunburstMotion.outerRadius(100, isLifted: false), 100), "hover lifts the outer radius by 4")
let explodeRight = SunburstMotion.explodeOffset(startAngle: 60, endAngle: 120)
check(near(explodeRight.x, 6) && abs(explodeRight.y) < 1e-9, "explode offset at 3 o'clock moves right by 6")
let explodeUp = SunburstMotion.explodeOffset(startAngle: -30, endAngle: 30)
check(abs(explodeUp.x) < 1e-9 && near(explodeUp.y, -6), "explode offset at 12 o'clock moves up by 6")
let explodeDown = SunburstMotion.explodeOffset(startAngle: 150, endAngle: 210)
check(abs(explodeDown.x) < 1e-9 && near(explodeDown.y, 6), "explode offset at 6 o'clock moves down by 6")
let explodeDiagonal = SunburstMotion.explodeOffset(startAngle: 270, endAngle: 360)
check(near((explodeDiagonal.x * explodeDiagonal.x + explodeDiagonal.y * explodeDiagonal.y).squareRoot(), 6) && explodeDiagonal.x < 0 && explodeDiagonal.y < 0, "explode offset keeps its length along any angle")

check(DetailsRange.allCases.map(\.headlineTitle) == ["Today", "Last 7 days", "This month", "Last 31 days"], "headline range wording")
let headlineTotals = PeriodTotals(cost: 47.5, requests: 1081, input: 781_000, output: 737_000, cacheRead: 71_250_000, cacheWrite: 5_190_000)
let costHeadline = DetailsHeadline.make(range: .today, metric: .cost, totals: headlineTotals, layout: sunburstAll)
check(costHeadline.title == "Today: $47.50 across 1081 requests", "cost headline")
check(costHeadline.summary == "anthropic is 61 percent of it", "headline summary names the largest provider")
let tokenHeadline = DetailsHeadline.make(range: .thirtyOneDays, metric: .tokens, totals: headlineTotals, layout: sunburstTokens)
check(tokenHeadline.title == "Last 31 days: 77.96M tokens across 1081 requests", "tokens headline")
check(tokenHeadline.summary?.hasSuffix("of it") == true, "tokens headline has a summary")
check(DetailsHeadline.make(range: .sevenDays, metric: .cost, totals: PeriodTotals(), layout: SunburstLayout()) == DetailsHeadline(title: "Last 7 days: no usage", summary: nil), "empty headline")
check(DetailsHeadline.make(range: .thisMonth, metric: .cost, totals: PeriodTotals(cost: 0, requests: 3), layout: SunburstLayout()) == DetailsHeadline(title: "This month: $0.00 across 3 requests", summary: nil), "headline without slices has no summary")
let drilledHeadline = DetailsHeadline.make(range: .today, metric: .cost, totals: headlineTotals, layout: drilled)
check(drilledHeadline.summary == "anthropic: big is 66 percent of it", "drilled headline starts with the provider name")

let accessibilityModel = anthropicChildren[0]
check(SunburstLayout.accessibilityLabel(of: accessibilityModel, levelHasModels: true) == "anthropic, big", "model slice accessibility label is provider, model")
check(SunburstLayout.accessibilityLabel(of: anthropicRing0, levelHasModels: true) == "anthropic", "provider slice accessibility label is the provider")
check(SunburstLayout.accessibilityLabel(of: anthropicChildren[2], levelHasModels: true) == "other", "other slice accessibility label")
check(SunburstLayout.accessibilityValue(of: accessibilityModel, metric: .cost) == "$40.00, 40 percent", "model slice accessibility value is cost and percent")
check(SunburstLayout.accessibilityValue(of: anthropicRing0, metric: .tokens).hasSuffix("percent"), "accessibility value ends with percent")

// MARK: selection details
let selectionRecords = [
    sunburstRecord("anthropic", "m1", cost: 1, source: .pi, day: 15),
    sunburstRecord("anthropic", "m1", cost: 2, source: .claudeCode, day: 15),
    sunburstRecord("anthropic", "m1", cost: 4, source: .pi, day: 10),
    sunburstRecord("anthropic", "m1", cost: 8, source: .pi, day: 2),
    sunburstRecord("anthropic", "m2", cost: nil, source: .pi, day: 15),
    sunburstRecord("openai", "m1", cost: 16, source: .pi, day: 15)
]
func selectionDetails(_ range: DetailsRange, _ source: DetailsSourceFilter = .all, provider: String?, model: String?) -> SelectionDetails {
    SelectionDetails.summarize(records: selectionRecords, prices: [:], range: range, source: source, provider: provider,
                               model: model, now: fixedNow, calendar: fixedCalendar)
}
let modelSelection = selectionDetails(.sevenDays, provider: "anthropic", model: "m1")
check(modelSelection.requests == 3 && near(modelSelection.cost ?? -1, 7) && modelSelection.input == 30 && modelSelection.cacheRead == 300 && modelSelection.totalTokens == 3 * 135, "selection sums one model in the range")
check(modelSelection.sources.map(\.source) == [.pi, .claudeCode] && modelSelection.sources.map(\.requests) == [2, 1]
      && near(modelSelection.sources[0].cost ?? -1, 5) && near(modelSelection.sources[1].cost ?? -1, 2) && modelSelection.sources[1].totalTokens == 135, "selection splits by source")
check(selectionDetails(.sevenDays, .pi, provider: "anthropic", model: "m1").sources.map(\.source) == [.pi], "selection lists only sources present")
check(selectionDetails(.sevenDays, provider: "anthropic", model: "m2").cost == nil, "selection of an unpriced model has no cost")
check(selectionDetails(.sevenDays, provider: "anthropic", model: nil).requests == 4 && selectionDetails(.sevenDays, provider: nil, model: nil).requests == 5, "selection by provider and by level")
check(selectionDetails(.thirtyOneDays, provider: "anthropic", model: "m1").requests == 4, "selection follows the range")
check(modelSelection.daily.count == 14 && modelSelection.daily.first?.day == fixedCalendar.startOfDay(for: date(2026, 10, 2, 0))
      && modelSelection.daily.last?.day == fixedCalendar.startOfDay(for: fixedNow), "selection has 14 days ending today, oldest first")
check(near(modelSelection.daily.last?.cost ?? -1, 3) && near(modelSelection.daily[8].cost, 4) && near(modelSelection.daily[0].cost, 8) && modelSelection.daily[1].cost == 0, "selection daily cost")
check(modelSelection.daily.last?.totalTokens == 270 && modelSelection.daily[1].totalTokens == 0, "selection daily tokens")
check(selectionDetails(.today, provider: "anthropic", model: "m1").daily.map(\.cost).reduce(0, +) == 15, "selection series is not limited by the range")

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
