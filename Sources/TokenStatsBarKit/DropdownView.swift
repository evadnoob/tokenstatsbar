import Charts
import SwiftUI

struct DropdownView: View {
    @ObservedObject var store: UsageStore
    // The @State macro needs a compiler plugin that the Command Line Tools do not ship, so this uses an ObservableObject.
    @StateObject private var about = AboutPresentation()

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
    }

    private var todaySection: some View {
        let today = store.summary.today
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                Text(UsageFormat.cost(today.cost)).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Text("\(UsageFormat.tokens(today.tokens)) tokens · \(UsageFormat.requests(today.requests))")
                .font(.callout).foregroundStyle(.secondary)
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
            Text("BY MODEL · TODAY").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No usage today").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.model) { index, row in
                let color = DropdownView.modelColor(index: index, model: row.model)
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(row.model).lineLimit(1).truncationMode(.middle).frame(width: 110, alignment: .leading)
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
        }
    }

    /// Each daily bar fades from teal at the bottom to purple at the top.
    static let dailyGradient = LinearGradient(colors: [.teal, .blue, .purple], startPoint: .bottom, endPoint: .top)

    /// Model rows are ordered by cost, so the color follows the rank. The "other" row is always gray.
    static let modelPalette: [Color] = [.orange, .pink, .purple]

    static func modelColor(index: Int, model: String) -> Color {
        if model == UsageSummary.otherModelName { return .gray }
        return modelPalette[index % modelPalette.count]
    }

    private func updatedText(at date: Date) -> String {
        guard let updated = store.lastUpdated else { return "Not updated yet" }
        return "Updated " + UsageFormat.age(seconds: Int(date.timeIntervalSince(updated)))
    }
}
