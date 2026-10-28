import Foundation
import SwiftUI

/// Owns the ingestor and watcher and publishes the summary for the UI. File reading happens on a private queue.
@MainActor
public final class UsageStore: ObservableObject {
    @Published private(set) var summary = UsageSummary()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorText: String?

    private let ingestor: SessionLogIngestor
    private let queue = DispatchQueue(label: "com.evadnoob.tokenstatsbar.ingest", qos: .utility)
    private var watcher: SessionWatcher?

    public init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        ingestor = SessionLogIngestor(rootDirectory: directory)
        watcher = SessionWatcher(directory: directory) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
        refresh()
    }

    func refresh() {
        let ingestor = ingestor
        queue.async { [weak self] in
            let now = Date()
            let calendar = Calendar.current
            let outcome: Result<UsageSummary, Error> = Result {
                let records = try ingestor.refresh(now: now, calendar: calendar)
                return UsageSummary.summarize(records: records, now: now, calendar: calendar)
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
            errorText = "Cannot read session logs in ~/.pi/agent/sessions."
        }
        lastUpdated = date
    }

    var menuBarTokens: String {
        errorText == nil && lastUpdated != nil ? UsageFormat.tokens(summary.today.tokens) : "--"
    }
}
