import Foundation

enum SessionLogError: Error, Equatable {
    case directoryUnreadable(String)
}

/// Reads session logs incrementally. Each file keeps a byte offset to the end of its last complete line, so a
/// refresh reads only appended bytes and an incomplete trailing line is read again once it is finished.
/// Not thread safe: use it from one queue, which is why it is marked as unchecked Sendable.
final class SessionLogIngestor: @unchecked Sendable {
    struct FileState {
        var offset: UInt64
        var fileIdentifier: UInt64
        var records: [UsageRecord]
    }

    let rootDirectory: URL
    let source: UsageSource
    private(set) var states: [String: FileState] = [:]
    static let retentionDays = 31

    init(rootDirectory: URL, source: UsageSource = .pi) {
        self.rootDirectory = rootDirectory
        self.source = source
    }

    /// Reads new bytes from every log file and returns the records of the last 31 days. A response that a log
    /// writes as several lines is returned once, with the largest token counts.
    func refresh(now: Date, calendar: Calendar) throws -> [UsageRecord] {
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        let paths = try logFilePaths(modifiedSince: cutoff)
        for path in Set(states.keys).subtracting(paths) { states[path] = nil }
        for path in paths { readAppended(path: path) }
        var result: [UsageRecord] = []
        for path in states.keys {
            states[path]?.records.removeAll { $0.date < cutoff }
            result.append(contentsOf: states[path]?.records ?? [])
        }
        return UsageRecord.deduplicated(result)
    }

    private func logFilePaths(modifiedSince cutoff: Date) throws -> Set<String> {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in failed = true; return true }) else {
            throw SessionLogError.directoryUnreadable(rootDirectory.path)
        }
        var paths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < cutoff, states[url.path] == nil { continue }
            paths.insert(url.path)
        }
        if failed && paths.isEmpty { throw SessionLogError.directoryUnreadable(rootDirectory.path) }
        return paths
    }

    private func readAppended(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let identifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return }
        var state = states[path] ?? FileState(offset: 0, fileIdentifier: identifier, records: [])
        // A smaller size or a different file means the log was truncated or replaced: start over.
        if size < state.offset || identifier != state.fileIdentifier {
            state = FileState(offset: 0, fileIdentifier: identifier, records: [])
        }
        guard size > state.offset, let handle = FileHandle(forReadingAtPath: path) else {
            states[path] = state
            return
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.readToEnd() else {
            states[path] = state
            return
        }
        let chunk = UsageParser.parseChunk(data, source: source)
        state.records.append(contentsOf: chunk.records)
        // Claude Code repeats one response over several lines, so collapse them here to keep memory bounded.
        state.records = UsageRecord.deduplicated(state.records)
        state.offset += UInt64(chunk.consumedByteCount)
        states[path] = state
    }
}
