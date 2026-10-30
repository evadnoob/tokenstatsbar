import Charts
import SwiftUI

struct DropdownView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var details: UsageDetailsModel
    @Environment(\.openWindow) private var openWindow
    // The @State macro needs a compiler plugin that the Command Line Tools do not ship, so this uses an ObservableObject.
    @StateObject private var about = AboutPresentation()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var rowHover = RowHover()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorText = store.errorText {
                Text(errorText).font(.callout).foregroundStyle(.secondary)
            } else {
                todaySection
                Divider()
                periodRows
                Divider()
                modelSection
                Divider()
                tokenSection
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        // The setting can also change in System Settings, so read it again each time the dropdown opens.
        .onAppear { launchAtLogin.refresh() }
    }

    private var todaySection: some View {
        let today = store.summary.today
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("Today").font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(UsageFormat.cost(today.cost)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("API-equivalent").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(UsageFormat.tokens(today.tokens)) tokens · \(UsageFormat.requests(today.requests))")
                .font(.callout).foregroundStyle(.secondary)
            if store.summary.unpricedRequestsToday > 0 {
                Text("cost excludes \(store.summary.unpricedRequestsToday) unpriced "
                     + (store.summary.unpricedRequestsToday == 1 ? "request" : "requests"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart(store.summary.daily, id: \.day) { item in
                BarMark(x: .value("Day", item.day, unit: .day), y: .value("Cost", item.cost))
                    .foregroundStyle(DropdownView.dailyGradient)
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
        }
    }

    private var periodRows: some View {
        VStack(spacing: 6) {
            costRow("7 days", store.summary.sevenDays.cost)
            costRow("This month", store.summary.thisMonth.cost)
        }
    }

    private func costRow(_ title: String, _ cost: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(UsageFormat.cost(cost)).monospacedDigit()
        }
    }

    private var modelSection: some View {
        let rows = UsageSummary.groupedModels(store.summary.modelsToday)
        let topCost = rows.first?.cost ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("BY PROVIDER/MODEL · TODAY").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No usage today").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in
                let color = DropdownView.color(for: row)
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(row.name).lineLimit(1).truncationMode(.middle).frame(width: 120, alignment: .leading)
                        .help(row.name)
                    GeometryReader { proxy in
                        let fraction = topCost > 0 ? min(row.cost / topCost, 1) : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 2 : 0), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    Text(UsageFormat.cost(row.cost)).monospacedDigit().frame(minWidth: 50, alignment: .trailing)
                }
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(rowHover.hoveredName == row.name ? Color.primary.opacity(0.06) : Color.clear))
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering { rowHover.hoveredName = row.name } else if rowHover.hoveredName == row.name { rowHover.hoveredName = nil }
                }
                .onTapGesture {
                    // The dropdown rows cover both sources, so show both and the clicked row is always visible.
                    details.sourceFilter = .all
                    details.drillProvider = row.provider
                    details.hover.hoveredSliceID = nil
                    showDetails(range: .today, selecting: row.isOther ? nil : row.name)
                }
            }
        }
    }

    private var tokenSection: some View {
        let today = store.summary.today
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tokens today").font(.caption).foregroundStyle(.secondary)
            Text("input \(UsageFormat.tokens(today.input))  output \(UsageFormat.tokens(today.output))")
            Text("cache read \(UsageFormat.tokens(today.cacheRead))  cache write \(UsageFormat.tokens(today.cacheWrite))")
        }
        .font(.callout.monospacedDigit())
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedText(at: context.date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { about.isShown.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("About these numbers")
                .popover(isPresented: $about.isShown, arrowEdge: .bottom) { AboutView() }
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit")
            Menu {
                Button("Refresh now") { store.refresh() }
                PriceCacheMenu(controller: store.priceCache)
                LaunchAtLoginMenuItems(controller: launchAtLogin)
                Button("Show details...") { showDetails(range: details.range, selecting: details.selectedRowID) }
                Button("About these numbers") {
                    // A popover does not open while the menu is still closing, so wait for the menu to close.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { about.isShown = true }
                }
                Divider()
                Button("Quit TokenStatsBar") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// Each daily bar fades from teal at the bottom to purple at the top.
    static let dailyGradient = LinearGradient(colors: [.teal, .blue, .purple], startPoint: .bottom, endPoint: .top)

    /// Rows take the color of their provider. The "other" row is always gray.
    static func color(for row: ModelCost) -> Color {
        guard let provider = row.provider else { return .gray }
        switch UsageSummary.tint(forProvider: provider) {
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .pink: return .pink
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    private func showDetails(range: DetailsRange, selecting rowID: String?) {
        details.range = range
        details.selectedRowID = rowID
        // The dropdown can close before the pointer leaves the row, so clear the hover highlight here.
        rowHover.hoveredName = nil
        openWindow(id: "usage-details")
        NSApp.activate(ignoringOtherApps: true)
        // An app without a Dock icon is often not allowed to become active, and then the window opens behind other
        // apps. Ordering the window itself to the front works even when the app is not active.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == UsageDetailsView.windowTitle }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func updatedText(at date: Date) -> String {
        guard let updated = store.lastUpdated else { return "Not updated yet" }
        return "Updated " + UsageFormat.age(seconds: Int(date.timeIntervalSince(updated)))
    }
}

/// The "Price cache" submenu of the footer menu.
struct PriceCacheMenu: View {
    @ObservedObject var controller: PriceCacheController

    var body: some View {
        Menu("Price cache") {
            Text(controller.builtAt.map { "Updated " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not built")
            Text("\(controller.modelCount) models")
            if let errorText = controller.errorText {
                Text(errorText)
            }
            Button(controller.isRebuilding ? "Rebuilding..." : "Rebuild price cache") { controller.rebuild() }
                .disabled(controller.isRebuilding)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([controller.fileURL])
            }
            .disabled(controller.builtAt == nil)
        }
    }
}
