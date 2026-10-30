import Charts
import SwiftUI

/// The right side of the details window, on the sidebar material: the slices of the current level, then the
/// details of the selection, then the Chart and Table control.
struct UsageDetailsSidePanel: View {
    static let width = 300.0

    let layout: SunburstLayout
    let selection: SelectionDetails
    let selectionName: String
    let selectionColor: Color
    @ObservedObject var model: UsageDetailsModel
    /// Only the slice list observes it, so a hover change does not rebuild the Selection section and the sparkline.
    let hover: SliceHover

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.drillProvider == nil ? "Providers" : "Models").font(.headline)
                        UsageDetailsSliceList(layout: layout, model: model, hover: hover)
                    }
                    selectionDetails
                }
            }
            Picker("View", selection: $model.showsTable) {
                Text("Chart").tag(false)
                Text("Table").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selection").font(.headline)
            Text(selectionName).font(.subheadline).lineLimit(2).truncationMode(.middle).help(selectionName)
            detailLine("Requests", "\(selection.requests)")
            detailLine("Input", UsageFormat.tokens(selection.input))
            detailLine("Output", UsageFormat.tokens(selection.output))
            detailLine("Cache read", UsageFormat.tokens(selection.cacheRead))
            detailLine("Cache write", UsageFormat.tokens(selection.cacheWrite))
            detailLine("Total tokens", UsageFormat.tokens(selection.totalTokens))
            detailLine("Cost", selection.cost.map(UsageFormat.cost) ?? "unpriced")
            if selection.sources.count > 1 {
                Text("By source").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(selection.sources, id: \.source) { breakdown in
                    detailLine(breakdown.source == .pi ? "pi" : "Claude Code",
                               "\(UsageFormat.tokens(breakdown.totalTokens)) tokens, "
                               + (breakdown.cost.map(UsageFormat.cost) ?? "unpriced"))
                }
            }
            Text("Last 14 days").font(.subheadline).foregroundStyle(.secondary).padding(.top, 4)
            sparkline
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var sparkline: some View {
        Chart(selection.daily) { point in
            BarMark(x: .value("Day", point.day, unit: .day),
                    y: .value(model.metric.title, model.metric == .cost ? point.cost : Double(point.totalTokens)))
                .foregroundStyle(selectionColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 50)
    }
}

/// The slices of the current level as a list. It observes the hover state, which the rest of the panel does not.
struct UsageDetailsSliceList: View {
    let layout: SunburstLayout
    @ObservedObject var model: UsageDetailsModel
    @ObservedObject var hover: SliceHover

    var body: some View {
        sliceList
    }

    private var levelSlices: [SunburstSlice] { layout.slices.filter { $0.ring == 0 } }

    private var sliceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(levelSlices) { slice in
                sliceRow(slice)
            }
        }
    }

    private func sliceRow(_ slice: SunburstSlice) -> some View {
        let name = SunburstView.fullName(slice)
        let isHighlighted = layout.isHighlighted(slice.id, hoveredID: hover.hoveredSliceID)
        let isSelected = slice.rowID != nil && slice.rowID == model.selectedRowID
        let color = SunburstPalette.color(for: slice)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(name)
                Spacer(minLength: 4)
                Text(model.metric.text(slice.value)).monospacedDigit()
                Text(String(format: "%.1f%%", slice.share))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: proxy.size.width * slice.share / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground(isSelected: isSelected, isHighlighted: isHighlighted)))
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hover.hoveredSliceID = slice.id
            } else if hover.hoveredSliceID == slice.id {
                hover.hoveredSliceID = nil
            }
        }
        .onTapGesture { model.activate(slice) }
    }

    /// The selected row uses the user's accent color, like a selected row of a system list.
    private func rowBackground(isSelected: Bool, isHighlighted: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.28) }
        return isHighlighted ? Color.primary.opacity(0.07) : Color.clear
    }
}
