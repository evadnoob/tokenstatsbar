// swift-tools-version:5.9
import PackageDescription

/// Test harness targets. tools/run-tests.sh runs every name in this list, so add new harnesses here.
let harnesses: [(name: String, path: String, exclude: [String])] = [
    ("UsageTests", "tools/usage-tests", [])
]

let package = Package(
    name: "TokenStatsBar",
    platforms: [.macOS(.v13)],
    targets: [
        // All app code. The app and the test harnesses link it.
        .target(
            name: "TokenStatsBarKit",
            path: "Sources/TokenStatsBarKit"),
        .executableTarget(
            name: "TokenStatsBar",
            dependencies: ["TokenStatsBarKit"],
            path: "Sources/TokenStatsBarMain"),
        // Test harnesses: one executable target per tools/<name> directory. They use "@testable import TokenStatsBarKit",
        // so they build only in the debug configuration.
    ] + harnesses.map { harness in
        .executableTarget(
            name: harness.name,
            dependencies: ["TokenStatsBarKit"],
            path: harness.path,
            exclude: harness.exclude)
    }
)
