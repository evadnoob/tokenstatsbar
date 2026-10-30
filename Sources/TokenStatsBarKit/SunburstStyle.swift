import Foundation

/// A color in hue, saturation and brightness, each from 0 to 1.
struct SunburstShade: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
}

/// The provider palette as plain numbers, so it can be tested without SwiftUI. SunburstPalette turns these into
/// dynamic colors.
enum SunburstColors {
    static let colorKeys = ["amber", "teal", "violet", "blue", "rose", "slate", "gray"]
    static let maximumShadeIndex = 6

    private static let hues: [String: Double] = [
        "amber": 0.115, "teal": 0.49, "violet": 0.74, "blue": 0.60, "rose": 0.96, "slate": 0.60, "gray": 0
    ]
    /// Slate is a muted blue and gray has no hue, so they keep only part of the saturation.
    private static let saturationScales: [String: Double] = ["slate": 0.25, "gray": 0]

    /// A model shade is a lightness step of the provider hue: rank 0 is the deepest and each rank is lighter.
    /// `tone` moves the brightness a little, from -1 (inner edge of a slice) to 1 (outer edge).
    static func shade(colorKey: String, shadeIndex: Int, isDark: Bool, tone: Double = 0) -> SunburstShade {
        let rank = Double(min(max(shadeIndex, 0), maximumShadeIndex))
        let scale = saturationScales[colorKey] ?? 1
        // The light variant stays below 0.9 brightness and above 0.5 saturation so the lightest shade still
        // separates from a white background.
        let saturation = (isDark ? 0.62 - 0.06 * rank : 0.74 - 0.035 * rank) * scale
        let brightness = isDark ? 0.80 + 0.035 * rank + 0.05 * tone : 0.70 + 0.025 * rank + 0.035 * tone
        return SunburstShade(hue: hues[colorKey] ?? 0, saturation: saturation, brightness: min(max(brightness, 0), 1))
    }
}

/// The motion geometry of the sunburst, in points.
enum SunburstMotion {
    /// How much the outer radius of a hovered slice grows.
    static let hoverLift = 4.0
    /// How far the selected model slice moves outward along its center angle.
    static let explodeDistance = 6.0

    static func outerRadius(_ radius: Double, isLifted: Bool) -> Double {
        isLifted ? radius + hoverLift : radius
    }

    /// The offset of a slice that moves `distance` outward along its center angle. Angles are degrees, 0 at
    /// 12 o'clock and growing clockwise, and y grows downward.
    static func explodeOffset(startAngle: Double, endAngle: Double, distance: Double = explodeDistance)
        -> (x: Double, y: Double) {
        let center = (startAngle + endAngle) / 2 * Double.pi / 180
        return (distance * sin(center), -distance * cos(center))
    }
}

/// The headline and the summary line above the chart.
struct DetailsHeadline: Equatable {
    var title: String
    /// nil when there is no slice to name.
    var summary: String?

    /// "Today: $47.50 across 1,081 requests" with the largest slice in the summary. The slices of the first ring
    /// are the largest providers (or the models, in a drilled level), with "other" last.
    static func make(range: DetailsRange, metric: DetailsMetric, totals: PeriodTotals, layout: SunburstLayout)
        -> DetailsHeadline {
        guard totals.requests > 0 else {
            return DetailsHeadline(title: "\(range.headlineTitle): no usage", summary: nil)
        }
        let amount = metric == .cost ? UsageFormat.cost(totals.cost) : "\(UsageFormat.tokens(totals.tokens)) tokens"
        let title = "\(range.headlineTitle): \(amount) across \(UsageFormat.requests(totals.requests))"
        guard let largest = layout.slices.first(where: { $0.ring == 0 }), !largest.isOther else {
            return DetailsHeadline(title: title, summary: nil)
        }
        let percent = Int(largest.share.rounded())
        let share = percent < 1 ? "less than 1 percent" : "\(percent) percent"
        // A drilled level has one ring that holds the models of a single provider, so the summary names it.
        let subject = layout.ringCount == 1 ? largest.provider.map { "\($0): \(largest.name)" } ?? largest.name
            : largest.name
        return DetailsHeadline(title: title, summary: "\(subject) is \(share) of it")
    }
}
