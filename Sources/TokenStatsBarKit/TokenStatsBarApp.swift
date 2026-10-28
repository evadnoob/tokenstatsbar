import AppKit
import SwiftUI

public struct TokenStatsBarApp: App {
    @StateObject private var store = UsageStore()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            DropdownView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(store.menuBarTokens).monospacedDigit()
        }
    }
}
