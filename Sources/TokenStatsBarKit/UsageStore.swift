import Foundation
import SwiftUI

/// Owns the ingestors, the price cache and the watcher, and publishes the summary for the UI.
/// File reading happens on a private queue.
@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var summary = UsageSummary()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorText: String?

    let priceCache: PriceCacheController
    private let ingestors: [SessionLogIngestor]
    private let queue = DispatchQueue(label: "com.evadnoob.tokenstatsbar.ingest", qos: .utility)
    private var watcher: SessionWatcher?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources: [UsageSource] = [.pi, .claudeCode]
        ingestors = sources.flatMap { source in
            source.rootDirectories(home: home).map { SessionLogIngestor(rootDirectory: $0, source: source) }
        }
        priceCache = PriceCacheController(fileURL: PriceCache.defaultFileURL(home: home))
        priceCache.onChange = { [weak self] in self?.refresh() }
        watcher = SessionWatcher(directories: ingestors.map(\.rootDirectory)) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
        refresh()
        priceCache.buildIfMissing()
    }

    func refresh() {
        let ingestors = ingestors
        let prices = priceCache.models
        queue.async { [weak self] in
            let now = Date()
            let calendar = Calendar.current
            let outcome: Result<UsageSummary, Error> = Result {
                // A root that does not exist is normal, for example when only one of the tools is installed.
                // It is an error only when no root can be read.
                var records: [UsageRecord] = []
                var firstError: Error?
                var readableCount = 0
                for ingestor in ingestors {
                    do {
                        records.append(contentsOf: try ingestor.refresh(now: now, calendar: calendar))
                        readableCount += 1
                    } catch {
                        firstError = firstError ?? error
                    }
                }
                if readableCount == 0, let firstError { throw firstError }
                return UsageSummary.summarize(
                    records: UsageRecord.deduplicated(records), prices: prices, now: now, calendar: calendar)
            }
            DispatchQueue.main.async {
                self?.apply(outcome, at: now)
            }
        }
    }

    private func apply(_ outcome: Result<UsageSummary, Error>, at date: Date) {
        switch outcome {
        case .success(let value):
            summary = value
            errorText = nil
        case .failure:
            errorText = "Cannot read session logs in ~/.pi/agent/sessions, ~/.claude/projects or ~/.config/claude/projects."
        }
        lastUpdated = date
    }

    var menuBarTokens: String {
        errorText == nil && lastUpdated != nil ? UsageFormat.tokens(summary.today.tokens) : "--"
    }
}
