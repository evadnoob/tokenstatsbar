import SwiftUI

struct UsageDetailsView: View {
    static let windowTitle = "TokenStatsBar: usage details"

    @ObservedObject var store: UsageStore
    @ObservedObject var model: UsageDetailsModel
    /// Owned here so the intro sweep plays once per window and not again after a switch to the table.
    @StateObject private var intro = SunburstIntro()

    var body: some View {
        let now = store.lastUpdated ?? Date()
        let calendar = Calendar.current
        let levelRecords = model.drillProvider.map { provider in store.records.filter { $0.provider == provider } }
            ?? store.records
        let details = UsageDetails.summarize(
            records: levelRecords, prices: store.prices, range: model.range, source: model.sourceFilter,
            now: now, calendar: calendar)
        let layout = SunburstLayout.layout(rows: details.rows, metric: model.metric, drillProvider: model.drillProvider)
        let selectedRow = details.rows.first { $0.id == model.selectedRowID }
        let selection = SelectionDetails.summarize(
            records: store.records, prices: store.prices, range: model.range, source: model.sourceFilter,
            provider: selectedRow?.provider ?? model.drillProvider, model: selectedRow?.model, now: now,
            calendar: calendar)
        let levelName = model.drillProvider ?? "All"
        let headline = DetailsHeadline.make(range: model.range, metric: model.metric, totals: details.totals,
                                            layout: layout)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headlineView(headline)
                mainArea(details: details, layout: layout, levelName: levelName)
                footnote(details)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            UsageDetailsSidePanel(layout: layout, selection: selection,
                                  selectionName: selectedRow?.name ?? levelName,
                                  selectionColor: selectionColor(layout: layout, selectedRow: selectedRow),
                                  model: model, hover: model.hover)
        }
        .background(escapeButton)
        .toolbar {
            ToolbarItem(placement: .navigation) { breadcrumbs }
            ToolbarItem(placement: .principal) { rangePicker }
            ToolbarItemGroup(placement: .primaryAction) {
                sourcePicker
                metricPicker
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    /// The color of the selected model, else of the drilled provider, else the accent color.
    private func selectionColor(layout: SunburstLayout, selectedRow: UsageDetailRow?) -> Color {
        if let selectedRow, let slice = layout.slices.first(where: { $0.rowID == selectedRow.id }) {
            return SunburstPalette.color(for: slice)
        }
        if let provider = model.drillProvider {
            return SunburstPalette.color(colorKey: SunburstLayout.colorKey(forProvider: provider), shadeIndex: 0)
        }
        return Color.accentColor
    }

    /// Escape goes up one level.
    private var escapeButton: some View {
        Button("Up one level") { model.goUp() }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    private func headlineView(_ headline: DetailsHeadline) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(headline.title).font(.title3).fontWeight(.semibold).monospacedDigit()
            if let summary = headline.summary {
                Text(summary).foregroundStyle(.secondary)
            }
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $model.range) {
            ForEach(DetailsRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 340)
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $model.sourceFilter) {
            ForEach(DetailsSourceFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .help("Source")
    }

    private var metricPicker: some View {
        Picker("Metric", selection: $model.metric) {
            Image(systemName: "dollarsign").help("Cost").accessibilityLabel("Cost").tag(DetailsMetric.cost)
            Image(systemName: "number").help("Tokens").accessibilityLabel("Tokens").tag(DetailsMetric.tokens)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Cost or tokens")
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button("All") { model.goUp() }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(model.drillProvider == nil ? Color.primary : Color.accentColor)
            if let provider = model.drillProvider {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                Text(provider).font(.headline).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func mainArea(details: UsageDetails, layout: SunburstLayout, levelName: String) -> some View {
        if details.rows.isEmpty {
            Text("No usage in this range").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.showsTable {
            table(details)
        } else if layout.slices.isEmpty {
            Text("No priced usage in this range. Choose Tokens to see unpriced models.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SunburstView(layout: layout, levelName: levelName, rangeTitle: model.range.title, metric: model.metric,
                         model: model, hover: model.hover, intro: intro)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func table(_ details: UsageDetails) -> some View {
        let sort = model.sortColumn
        let rows = UsageDetails.sorted(details.rows, by: sort.column, ascending: sort.ascending)
        return Table(rows, selection: $model.selectedRowID, sortOrder: $model.sortOrder) {
            TableColumn("Provider/model", value: \.name) { row in
                Text(row.name)
            }
            TableColumn("Requests", value: \.requests) { row in
                numberText("\(row.requests)")
            }
            TableColumn("Input", value: \.input) { row in
                numberText(UsageFormat.tokens(row.input))
            }
            TableColumn("Output", value: \.output) { row in
                numberText(UsageFormat.tokens(row.output))
            }
            TableColumn("Cache read", value: \.cacheRead) { row in
                numberText(UsageFormat.tokens(row.cacheRead))
            }
            TableColumn("Cache write", value: \.cacheWrite) { row in
                numberText(UsageFormat.tokens(row.cacheWrite))
            }
            TableColumn("Total tokens", value: \.totalTokens) { row in
                numberText(UsageFormat.tokens(row.totalTokens))
            }
            TableColumn("Cost", value: \.costSortValue) { row in
                numberText(row.cost.map(UsageFormat.cost) ?? "unpriced")
            }
            TableColumn("Share", value: \.share) { row in
                numberText(String(format: "%.1f%%", row.share))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func numberText(_ text: String) -> some View {
        Text(text).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func footnote(_ details: UsageDetails) -> some View {
        Text("All costs are API-equivalent."
             + (details.unpricedRequests > 0
                ? " \(details.unpricedRequests) unpriced \(details.unpricedRequests == 1 ? "request" : "requests")." : ""))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
