import Foundation

enum UsageFormat {
    /// 999 stays plain, 1.5K and 48K use K, 1.24M uses M.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if count >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if count >= 100_000 { return String(format: "%.0fK", value / 1000) }
        if count >= 10_000 { return trimmed(String(format: "%.1f", value / 1000)) + "K" }
        if count >= 1000 { return trimmed(String(format: "%.2f", value / 1000)) + "K" }
        return String(count)
    }

    /// Dollars with two decimals and grouping, for example "$4.82" or "$1,234.50".
    static func cost(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }

    /// "Updated 12s ago" style text.
    static func age(seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0))s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    static func requests(_ count: Int) -> String {
        "\(count) \(count == 1 ? "request" : "requests")"
    }

    private static func trimmed(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
