import AppKit
import SwiftUI

/// The colors of the sunburst: dynamic colors with a light and a dark variant. Each provider has a hue and its
/// models use lightness steps of it. The chart, the list and the sparkline all use these.
@MainActor
enum SunburstPalette {
    private struct CacheKey: Hashable {
        var colorKey: String
        var shadeIndex: Int
        var tone: Double
    }

    private static var cache: [CacheKey: Color] = [:]

    /// One dynamic color per key, shade and tone, so a redraw does not create new NSColor objects.
    static func color(colorKey: String, shadeIndex: Int, tone: Double = 0) -> Color {
        let key = CacheKey(colorKey: colorKey, shadeIndex: shadeIndex, tone: tone)
        if let cached = cache[key] { return cached }
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let shade = SunburstColors.shade(colorKey: colorKey, shadeIndex: shadeIndex, isDark: isDark, tone: tone)
            return NSColor(hue: shade.hue, saturation: shade.saturation, brightness: shade.brightness, alpha: 1)
        })
        cache[key] = color
        return color
    }

    static func color(for slice: SunburstSlice, tone: Double = 0) -> Color {
        color(colorKey: slice.colorKey, shadeIndex: slice.shadeIndex, tone: tone)
    }
}

/// An annular sector drawn from straight segments. Angles are degrees, 0 at 12 o'clock, clockwise.
/// The sector is inset on every side so neighbours leave a small gap in the background color.
struct SunburstSliceShape: Shape {
    var startAngle: Double
    var endAngle: Double
    var innerRadius: Double
    var outerRadius: Double

    static let inset = 1.0

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(startAngle, endAngle), AnimatablePair(innerRadius, outerRadius)) }
        set {
            startAngle = newValue.first.first
            endAngle = newValue.first.second
            innerRadius = newValue.second.first
            outerRadius = newValue.second.second
        }
    }

    /// The bounding box of the arc of a slice relative to the center, found from the corners and the extremes of
    /// the arc that lie inside the angle range.
    static func boundingBox(startAngle: Double, endAngle: Double, innerRadius: Double, outerRadius: Double) -> CGRect {
        var angles = [startAngle, endAngle]
        var quarter = (startAngle / 90).rounded(.up) * 90
        while quarter < endAngle {
            angles.append(quarter)
            quarter += 90
        }
        var xs: [Double] = []
        var ys: [Double] = []
        for angle in angles {
            let radians = angle * .pi / 180
            for radius in [innerRadius, outerRadius] {
                xs.append(radius * sin(radians))
                ys.append(-radius * cos(radians))
            }
        }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0, minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = innerRadius + Self.inset
        let outer = outerRadius - Self.inset
        guard outer > inner else { return Path() }
        // The gap between slices is a fixed length, converted to an angle per radius. On a narrow slice the gap
        // would leave nothing, so it is limited to a quarter of the slice on each side.
        let span = (endAngle - startAngle) * .pi / 180
        let innerGap = min(Self.inset / inner, span * 0.25)
        let outerGap = min(Self.inset / outer, span * 0.25)
        let innerStart = startAngle * .pi / 180 + innerGap
        let innerEnd = endAngle * .pi / 180 - innerGap
        let outerStart = startAngle * .pi / 180 + outerGap
        let outerEnd = endAngle * .pi / 180 - outerGap
        guard innerEnd > innerStart, outerEnd > outerStart else { return Path() }
        func point(_ angle: Double, _ radius: Double) -> CGPoint {
            CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        }
        let steps = max(2, Int((endAngle - startAngle) / 2))
        var path = Path()
        path.move(to: point(outerStart, outer))
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            path.addLine(to: point(outerStart + (outerEnd - outerStart) * fraction, outer))
        }
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            path.addLine(to: point(innerEnd - (innerEnd - innerStart) * fraction, inner))
        }
        path.closeSubpath()
        return path
    }
}

/// A pie wedge from 12 o'clock clockwise, used as a mask for the intro sweep. Progress 1 covers everything.
struct SunburstSweepShape: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if progress >= 1 { return Path(rect) }
        guard progress > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = Double(max(rect.width, rect.height))
        let steps = max(2, Int(progress * 120))
        var path = Path()
        path.move(to: center)
        for step in 0...steps {
            let angle = progress * 2 * Double.pi * Double(step) / Double(steps)
            path.addLine(to: CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle)))
        }
        path.closeSubpath()
        return path
    }
}

/// The intro sweep plays once, the first time the sunburst appears. Owned by the window so toggling between the
/// chart and the table does not replay it.
@MainActor
final class SunburstIntro: ObservableObject {
    @Published private(set) var progress = 0.0
    private var hasPlayed = false

    func play(reduceMotion: Bool) {
        guard !hasPlayed else { return }
        hasPlayed = true
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .easeOut(duration: 0.9)) { progress = 1 }
    }
}

/// The circle of the sunburst inside a view of `size`.
struct SunburstGeometry {
    var size: CGSize
    var ringCount: Int

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    /// Leaves room for the explode offset and the hover lift.
    var outerRadius: Double { Double(min(size.width, size.height)) / 2 - 14 }
    var innerRadius: Double { outerRadius * (ringCount > 1 ? 0.34 : 0.45) }
    var ringThickness: Double { (outerRadius - innerRadius) / Double(max(ringCount, 1)) }

    func relativePoint(_ location: CGPoint) -> (x: Double, y: Double) {
        (Double(location.x - center.x), Double(location.y - center.y))
    }
}

struct SunburstView: View {
    let layout: SunburstLayout
    let levelName: String
    let rangeTitle: String
    let metric: DetailsMetric
    @ObservedObject var model: UsageDetailsModel
    /// Kept apart from the model so hover changes redraw only the sunburst and the list, not the whole window.
    @ObservedObject var hover: SliceHover
    @ObservedObject var intro: SunburstIntro
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunburstGeometry(size: proxy.size, ringCount: layout.ringCount)
            ZStack {
                ZStack {
                    ZStack {
                        ForEach(layout.slices) { slice in
                            sliceView(slice, geometry: geometry)
                        }
                    }
                    .id(model.drillProvider ?? "")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                }
                .animation(drillAnimation, value: model.drillProvider)
                .mask(SunburstSweepShape(progress: reduceMotion ? 1 : intro.progress))
                .opacity(reduceMotion ? intro.progress : 1)
                centerLabel(geometry: geometry)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                let hovered: String?
                var isOverCenter = false
                switch phase {
                case .active(let location):
                    let point = geometry.relativePoint(location)
                    hovered = layout.hitTest(point: point, innerRadius: geometry.innerRadius,
                                             outerRadius: geometry.outerRadius, selectedRowID: model.selectedRowID,
                                             hoveredID: hover.hoveredSliceID)
                    isOverCenter = (point.x * point.x + point.y * point.y).squareRoot() < geometry.innerRadius
                case .ended:
                    hovered = nil
                }
                if hover.hoveredSliceID != hovered { hover.hoveredSliceID = hovered }
                let showsBack = isOverCenter && model.drillProvider != nil
                if hover.isCenterHovered != showsBack { hover.isCenterHovered = showsBack }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                let point = geometry.relativePoint(tap.location)
                if let id = layout.hitTest(point: point, innerRadius: geometry.innerRadius,
                                           outerRadius: geometry.outerRadius, selectedRowID: model.selectedRowID,
                                           hoveredID: hover.hoveredSliceID),
                   let slice = layout.slices.first(where: { $0.id == id }) {
                    model.activate(slice)
                } else if (point.x * point.x + point.y * point.y).squareRoot() < geometry.innerRadius {
                    model.goUp()
                }
            })
            .accessibilityChartDescriptor(SunburstChartDescriptor(layout: layout, metric: metric, levelName: levelName,
                                                                  rangeTitle: rangeTitle))
            .onAppear { intro.play(reduceMotion: reduceMotion) }
        }
    }

    /// The spring of a drill down, or a short cross-fade with Reduce Motion.
    private var drillAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.85)
    }

    /// Hover lift and the explode offset: short and quiet, off with Reduce Motion.
    private var feedbackAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    private func sliceView(_ slice: SunburstSlice, geometry: SunburstGeometry) -> some View {
        let isLifted = layout.isHighlighted(slice.id, hoveredID: hover.hoveredSliceID)
        let isSelected = slice.rowID != nil && slice.rowID == model.selectedRowID
        let innerRadius = geometry.innerRadius + Double(slice.ring) * geometry.ringThickness
        let outerRadius = SunburstMotion.outerRadius(
            geometry.innerRadius + Double(slice.ring + 1) * geometry.ringThickness, isLifted: isLifted)
        let offset = isSelected
            ? SunburstMotion.explodeOffset(startAngle: slice.startAngle, endAngle: slice.endAngle) : (x: 0, y: 0)
        let shape = SunburstSliceShape(startAngle: slice.startAngle, endAngle: slice.endAngle,
                                       innerRadius: innerRadius, outerRadius: outerRadius)
        let gradient = RadialGradient(
            colors: [SunburstPalette.color(for: slice, tone: -1), SunburstPalette.color(for: slice, tone: 1)],
            center: .center, startRadius: innerRadius, endRadius: outerRadius)
        let box = SunburstSliceShape.boundingBox(
            startAngle: slice.startAngle, endAngle: slice.endAngle, innerRadius: geometry.innerRadius
                + Double(slice.ring) * geometry.ringThickness,
            outerRadius: geometry.innerRadius + Double(slice.ring + 1) * geometry.ringThickness)
        return shape.fill(gradient)
            .brightness(isLifted ? 0.08 : 0)
            .offset(x: offset.x, y: offset.y)
            .animation(feedbackAnimation, value: isLifted)
            .animation(feedbackAnimation, value: isSelected)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                // The element VoiceOver sees has the frame of the arc, not of the whole chart.
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .offset(x: geometry.center.x + box.minX + offset.x, y: geometry.center.y + box.minY + offset.y)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(SunburstLayout.accessibilityLabel(of: slice, levelHasModels: true))
                    .accessibilityValue(SunburstLayout.accessibilityValue(of: slice, metric: metric))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.activate(slice) }
            }
    }

    private func centerLabel(geometry: SunburstGeometry) -> some View {
        let focus = focusedSlice
        let value = focus.map { metric.text($0.value) } ?? metric.text(layout.total)
        let name = focus.map(Self.fullName) ?? levelName
        let detail = focus.map { String(format: "%.1f%% of %@", $0.share, levelName) } ?? rangeTitle
        return VStack(spacing: 2) {
            if hover.isCenterHovered {
                Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: geometry.innerRadius * 1.5)
        .allowsHitTesting(false)
    }

    /// The hovered slice, or else the selected model.
    private var focusedSlice: SunburstSlice? {
        if let hovered = hover.hoveredSliceID, let slice = layout.slices.first(where: { $0.id == hovered }) {
            return slice
        }
        guard let selected = model.selectedRowID else { return nil }
        return layout.slices.first { $0.rowID == selected }
    }

    static func fullName(_ slice: SunburstSlice) -> String {
        if slice.isOther { return UsageSummary.otherModelName }
        return slice.rowID ?? slice.name
    }
}

/// The audio graph of the sunburst for VoiceOver: one category per leaf slice with its value.
struct SunburstChartDescriptor: AXChartDescriptorRepresentable {
    let layout: SunburstLayout
    let metric: DetailsMetric
    let levelName: String
    let rangeTitle: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let leaves = layout.slices.filter { $0.ring == layout.ringCount - 1 }
        let labels = leaves.map { SunburstLayout.accessibilityLabel(of: $0, levelHasModels: true) }
        let maximum = max(leaves.map(\.value).max() ?? 1, 1)
        let xAxis = AXCategoricalDataAxisDescriptor(title: "Model", categoryOrder: labels)
        let yAxis = AXNumericDataAxisDescriptor(
            title: metric.title, range: 0...maximum, gridlinePositions: []) { metric.text($0) }
        let points = zip(labels, leaves).map { AXDataPoint(x: $0, y: $1.value) }
        let series = AXDataSeriesDescriptor(name: levelName, isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: "Usage by provider and model, \(rangeTitle)",
                                 summary: "\(metric.text(layout.total)) in total", xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = makeChartDescriptor()
        descriptor.title = fresh.title
        descriptor.summary = fresh.summary
        descriptor.xAxis = fresh.xAxis
        descriptor.yAxis = fresh.yAxis
        descriptor.series = fresh.series
    }
}

/// A material that adapts to the system appearance. The side panel uses the sidebar material.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
