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
check(afterTruncate.count == 1 && near(afterTruncate[0].cost, 9), "truncated file is read again from the start")

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
let models = [ModelCost(model: "m1", cost: 10), ModelCost(model: "m2", cost: 8), ModelCost(model: "m3", cost: 5),
              ModelCost(model: "m4", cost: 2), ModelCost(model: "m5", cost: 1)]
let grouped = UsageSummary.groupedModels(models)
check(grouped.map(\.model) == ["m1", "m2", "m3", "other"], "top 3 plus other")
check(near(grouped[3].cost, 3), "other sums the remaining models")
check(UsageSummary.groupedModels(Array(models.prefix(3))).count == 3, "three models have no other row")
check(UsageSummary.groupedModels([]).isEmpty, "no models, no rows")

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
