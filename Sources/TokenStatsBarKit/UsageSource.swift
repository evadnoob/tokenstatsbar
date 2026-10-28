import Foundation

/// Where usage records come from: the directories to read and how to parse one line.
enum UsageSource: String, Equatable {
    case pi
    case claudeCode

    /// The `claude` command line tool uses either directory, depending on its configuration.
    func rootDirectories(home: URL) -> [URL] {
        switch self {
        case .pi:
            return [home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)]
        case .claudeCode:
            return [home.appendingPathComponent(".claude/projects", isDirectory: true),
                    home.appendingPathComponent(".config/claude/projects", isDirectory: true)]
        }
    }

    func parse(line: Data) -> UsageRecord? {
        switch self {
        case .pi: return UsageParser.parse(line: line)
        case .claudeCode: return ClaudeCodeParser.parse(line: line)
        }
    }
}
