#if canImport(UIKit)
import Foundation

/// Counts the way the service writes them: 4494万, 14.6万, 9800.
public enum CountText {
    public static func short(_ value: Int) -> String {
        if value >= 100_000_000 { return trimmed(Double(value) / 100_000_000) + "亿" }
        if value >= 10_000 { return trimmed(Double(value) / 10_000) + "万" }
        return "\(value)"
    }

    private static func trimmed(_ number: Double) -> String {
        let text = String(format: number >= 100 ? "%.0f" : "%.1f", number)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// 11-09 within the current year, 2025-11-09 otherwise.
    public static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = sameYear ? "MM-dd" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
#endif
