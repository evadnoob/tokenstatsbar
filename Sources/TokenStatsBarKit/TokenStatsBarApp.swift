import AppKit
import SwiftUI

public struct TokenStatsBarApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var details = UsageDetailsModel()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            DropdownView(store: store, details: details)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        Window(UsageDetailsView.windowTitle, id: "usage-details") {
            UsageDetailsView(store: store, model: details)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 980, height: 640)
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
