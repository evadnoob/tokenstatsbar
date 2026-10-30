import Foundation
import SwiftUI

/// The state shared by the dropdown and the details window.
@MainActor
final class UsageDetailsModel: ObservableObject {
    @Published var range: DetailsRange = .today
    @Published var sourceFilter: DetailsSourceFilter = .all
    /// The table sort order. The default is cost, highest first.
    @Published var sortOrder: [KeyPathComparator<UsageDetailRow>] = [KeyPathComparator(\.costSortValue, order: .reverse)]
    @Published var selectedRowID: String?
    @Published var metric: DetailsMetric = .cost
    /// The provider the sunburst is drilled into. nil is the level "All".
    @Published var drillProvider: String?
    /// True when the main area shows the table instead of the sunburst.
    @Published var showsTable = false
    /// The sunburst slice that the pointer is over. A plain property, not @Published, so hovering does not
    /// recompute the whole window.
    let hover = SliceHover()

    func drill(into provider: String) {
        hover.hoveredSliceID = nil
        hover.isCenterHovered = false
        selectedRowID = nil
        drillProvider = provider
    }

    func goUp() {
        guard drillProvider != nil else { return }
        hover.hoveredSliceID = nil
        hover.isCenterHovered = false
        selectedRowID = nil
        drillProvider = nil
    }

    /// Clicking a slice or a list row: a provider at the level "All" is drilled into, a model is selected or,
    /// when it is already selected, deselected. "Other" does nothing.
    func activate(_ slice: SunburstSlice) {
        if slice.isOther { return }
        if let rowID = slice.rowID {
            selectedRowID = selectedRowID == rowID ? nil : rowID
        } else if let provider = slice.provider {
            drill(into: provider)
        }
    }

    /// The column and direction of the first sort comparator.
    var sortColumn: (column: DetailsColumn, ascending: Bool) {
        guard let comparator = sortOrder.first else { return (.cost, false) }
        let keyPath: PartialKeyPath<UsageDetailRow> = comparator.keyPath
        let columns: [(PartialKeyPath<UsageDetailRow>, DetailsColumn)] = [
            (\UsageDetailRow.name, .name), (\UsageDetailRow.requests, .requests), (\UsageDetailRow.input, .input),
            (\UsageDetailRow.output, .output), (\UsageDetailRow.cacheRead, .cacheRead),
            (\UsageDetailRow.cacheWrite, .cacheWrite), (\UsageDetailRow.totalTokens, .totalTokens),
            (\UsageDetailRow.costSortValue, .cost), (\UsageDetailRow.share, .share)
        ]
        let column = columns.first { $0.0 == keyPath }?.1 ?? .cost
        return (column, comparator.order == .forward)
    }
}

/// The id of the sunburst slice that the pointer is over, in the sunburst or in the side panel list.
@MainActor
final class SliceHover: ObservableObject {
    @Published var hoveredSliceID: String?
    /// True when the pointer is in the center hole of a drilled sunburst, where the back arrow shows.
    @Published var isCenterHovered = false
}

/// Which dropdown row the pointer is over. An ObservableObject because the @State macro needs a compiler plugin
/// that the Command Line Tools do not ship.
@MainActor
final class RowHover: ObservableObject {
    @Published var hoveredName: String?
}
