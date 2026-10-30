import Foundation

/// What the size of a slice measures.
enum DetailsMetric: String, CaseIterable, Identifiable {
    case cost
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        }
    }

    /// Cost counts only priced models, so an unpriced model has value 0 and no slice. Tokens count every model.
    func value(of row: UsageDetailRow) -> Double {
        switch self {
        case .cost: return row.cost ?? 0
        case .tokens: return Double(row.totalTokens)
        }
    }

    func text(_ value: Double) -> String {
        switch self {
        case .cost: return UsageFormat.cost(value)
        case .tokens: return UsageFormat.tokens(Int(value.rounded()))
        }
    }
}

/// One annular sector of the sunburst. Angles are degrees, 0 at 12 o'clock and growing clockwise.
struct SunburstSlice: Equatable, Identifiable {
    var id: String
    var name: String
    /// nil for the "other" slice of the provider ring.
    var provider: String?
    /// The row id (provider/model) of a model slice. nil for providers and for "other".
    var rowID: String?
    var ring: Int
    var startAngle: Double
    var endAngle: Double
    var value: Double
    /// Percent of the total of the current level.
    var share: Double
    var colorKey: String
    /// 0 for the largest model of a provider, growing with each rank. Providers and "other" use 0.
    var shadeIndex: Int
    var isOther: Bool

    var span: Double { endAngle - startAngle }
}

struct SunburstLayout: Equatable {
    var slices: [SunburstSlice] = []
    var total = 0.0
    var ringCount = 0

    /// Slices that span fewer degrees than this are merged into "other".
    static let minimumSliceDegrees = 1.5
    static let otherColorKey = "gray"

    /// The color family of a provider: amber, teal, blue, rose, violet or slate. "gray" is for "other" slices.
    static func colorKey(forProvider provider: String) -> String {
        let name = provider.lowercased()
        if name == "anthropic" { return "amber" }
        if name.hasPrefix("openai") { return "teal" }
        if name.contains("google") || name.contains("gemini") || name.contains("vertex") { return "blue" }
        if name == "xai" { return "rose" }
        if name.contains("copilot") { return "violet" }
        return "slate"
    }

    /// The accessibility label of a slice: "provider, model" for a model, the provider name for a provider.
    static func accessibilityLabel(of slice: SunburstSlice, levelHasModels: Bool) -> String {
        if slice.isOther { return UsageSummary.otherModelName }
        guard levelHasModels, slice.rowID != nil, let provider = slice.provider else { return slice.name }
        return "\(provider), \(slice.name)"
    }

    /// The accessibility value of a slice: "$38.52, 81 percent".
    static func accessibilityValue(of slice: SunburstSlice, metric: DetailsMetric) -> String {
        let percent = Int(slice.share.rounded())
        return "\(metric.text(slice.value)), \(percent) percent"
    }

    /// `drillProvider` nil is the level "All": providers in ring 0 and their models in ring 1. A provider fills
    /// ring 0 alone with its models when drilled in.
    static func layout(rows: [UsageDetailRow], metric: DetailsMetric, drillProvider: String?) -> SunburstLayout {
        let valued = rows.filter { metric.value(of: $0) > 0 && (drillProvider == nil || $0.provider == drillProvider) }
        let total = valued.reduce(0) { $0 + metric.value(of: $1) }
        guard total > 0 else { return SunburstLayout() }

        var modelsByProvider: [String: [UsageDetailRow]] = [:]
        for row in valued { modelsByProvider[row.provider, default: []].append(row) }
        for provider in modelsByProvider.keys {
            modelsByProvider[provider]?.sort { order($0, $1, metric) }
        }

        var layout = SunburstLayout(total: total)
        if let drillProvider {
            layout.ringCount = 1
            let models = modelsByProvider[drillProvider] ?? []
            layout.slices = modelSlices(models, provider: drillProvider, ring: 0, start: 0, span: 360,
                                        parentValue: total, levelTotal: total, metric: metric)
            return layout
        }

        layout.ringCount = 2
        let providers = modelsByProvider.keys.sorted { left, right in
            let leftValue = providerValue(modelsByProvider[left] ?? [], metric)
            let rightValue = providerValue(modelsByProvider[right] ?? [], metric)
            return leftValue != rightValue ? leftValue > rightValue : left < right
        }
        var angle = 0.0
        var mergedValue = 0.0
        for provider in providers {
            let models = modelsByProvider[provider] ?? []
            let value = providerValue(models, metric)
            let span = value / total * 360
            if span < minimumSliceDegrees {
                mergedValue += value
                continue
            }
            layout.slices.append(SunburstSlice(
                id: "0/\(provider)", name: provider, provider: provider, rowID: nil, ring: 0, startAngle: angle,
                endAngle: angle + span, value: value, share: value / total * 100,
                colorKey: colorKey(forProvider: provider), shadeIndex: 0, isOther: false))
            layout.slices += modelSlices(models, provider: provider, ring: 1, start: angle, span: span,
                                         parentValue: value, levelTotal: total, metric: metric)
            angle += span
        }
        if mergedValue > 0 {
            let span = mergedValue / total * 360
            let other = SunburstSlice(
                id: "0/other", name: UsageSummary.otherModelName, provider: nil, rowID: nil, ring: 0,
                startAngle: angle, endAngle: angle + span, value: mergedValue, share: mergedValue / total * 100,
                colorKey: otherColorKey, shadeIndex: 0, isOther: true)
            layout.slices.append(other)
            var child = other
            child.id = "1/other"
            child.ring = 1
            layout.slices.append(child)
        }
        return layout
    }

    /// The id of the slice under `point`, which is relative to the center of the sunburst with y growing downward.
    /// The rings share the band between `innerRadius` and `outerRadius` equally. nil in the hole and outside.
    /// It matches what is drawn: the selected model slice is tested first, shifted back by its explode offset, then
    /// the lifted slices of the outer ring with their lifted outer radius, then the plain rings.
    func hitTest(point: (x: Double, y: Double), innerRadius: Double, outerRadius: Double,
                 selectedRowID: String? = nil, hoveredID: String? = nil) -> String? {
        guard ringCount > 0, outerRadius > innerRadius else { return nil }
        let ringThickness = (outerRadius - innerRadius) / Double(ringCount)
        if let selectedRowID, let selected = slices.first(where: { $0.rowID == selectedRowID }) {
            let offset = SunburstMotion.explodeOffset(startAngle: selected.startAngle, endAngle: selected.endAngle)
            let shifted = (x: point.x - offset.x, y: point.y - offset.y)
            let isLifted = isOuterRing(selected) && isHighlighted(selected.id, hoveredID: hoveredID)
            if contains(selected, point: shifted, innerRadius: innerRadius, ringThickness: ringThickness,
                        isLifted: isLifted) {
                return selected.id
            }
        }
        if let hoveredID {
            let lifted = slices.first { isOuterRing($0) && isHighlighted($0.id, hoveredID: hoveredID)
                && contains($0, point: point, innerRadius: innerRadius, ringThickness: ringThickness, isLifted: true) }
            if let lifted { return lifted.id }
        }
        let radius = (point.x * point.x + point.y * point.y).squareRoot()
        guard radius >= innerRadius, radius < outerRadius else { return nil }
        let ring = min(Int((radius - innerRadius) / ringThickness), ringCount - 1)
        let degrees = Self.degrees(of: point)
        return slices.first { $0.ring == ring && degrees >= $0.startAngle && degrees < $0.endAngle }?.id
    }

    private func isOuterRing(_ slice: SunburstSlice) -> Bool { slice.ring == ringCount - 1 }

    private static func degrees(of point: (x: Double, y: Double)) -> Double {
        var degrees = atan2(point.x, -point.y) * 180 / Double.pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func contains(_ slice: SunburstSlice, point: (x: Double, y: Double), innerRadius: Double,
                          ringThickness: Double, isLifted: Bool) -> Bool {
        let radius = (point.x * point.x + point.y * point.y).squareRoot()
        let sliceInner = innerRadius + Double(slice.ring) * ringThickness
        let sliceOuter = SunburstMotion.outerRadius(innerRadius + Double(slice.ring + 1) * ringThickness,
                                                    isLifted: isLifted)
        guard radius >= sliceInner, radius < sliceOuter else { return false }
        let degrees = Self.degrees(of: point)
        return degrees >= slice.startAngle && degrees < slice.endAngle
    }

    /// True when `sliceID` is the hovered slice or belongs to a hovered provider slice of the level "All", so a provider
    /// and its models light up together.
    func isHighlighted(_ sliceID: String, hoveredID: String?) -> Bool {
        guard let hoveredID, let hovered = slices.first(where: { $0.id == hoveredID }),
              let slice = slices.first(where: { $0.id == sliceID }) else { return false }
        if slice.id == hovered.id { return true }
        guard ringCount == 2, hovered.ring == 0, slice.ring == 1 else { return false }
        return hovered.isOther ? slice.isOther && slice.provider == nil : slice.provider == hovered.provider
    }

    private static func providerValue(_ models: [UsageDetailRow], _ metric: DetailsMetric) -> Double {
        models.reduce(0) { $0 + metric.value(of: $1) }
    }

    private static func order(_ left: UsageDetailRow, _ right: UsageDetailRow, _ metric: DetailsMetric) -> Bool {
        let leftValue = metric.value(of: left)
        let rightValue = metric.value(of: right)
        return leftValue != rightValue ? leftValue > rightValue : left.name < right.name
    }

    /// The models of one provider inside the arc that starts at `start` and covers `span` degrees. Models below
    /// the minimum size are merged into one "other" slice at the end of the arc.
    private static func modelSlices(_ models: [UsageDetailRow], provider: String, ring: Int, start: Double,
                                    span: Double, parentValue: Double, levelTotal: Double,
                                    metric: DetailsMetric) -> [SunburstSlice] {
        var slices: [SunburstSlice] = []
        var angle = start
        var mergedValue = 0.0
        for (rank, row) in models.enumerated() {
            let value = metric.value(of: row)
            let modelSpan = value / parentValue * span
            if modelSpan < minimumSliceDegrees {
                mergedValue += value
                continue
            }
            slices.append(SunburstSlice(
                id: "\(ring)/\(row.name)", name: row.model, provider: provider, rowID: row.id, ring: ring,
                startAngle: angle, endAngle: angle + modelSpan, value: value, share: value / levelTotal * 100,
                colorKey: colorKey(forProvider: provider), shadeIndex: rank, isOther: false))
            angle += modelSpan
        }
        if mergedValue > 0 {
            slices.append(SunburstSlice(
                id: "\(ring)/other/\(provider)", name: UsageSummary.otherModelName, provider: provider, rowID: nil,
                ring: ring, startAngle: angle, endAngle: start + span, value: mergedValue,
                share: mergedValue / levelTotal * 100, colorKey: otherColorKey, shadeIndex: 0, isOther: true))
        }
        return slices
    }
}
