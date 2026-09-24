import Foundation

public enum Format {
    /// `0` → "–" (or `zero`), 30 s → "<1m", 12 min → "12m", 1 h 5 min → "1h 05m".
    public static func duration(_ seconds: Double, zero: String = "–") -> String {
        let total = Int(seconds.rounded())
        if total <= 0 { return zero }
        if total < 60 { return "<1m" }
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        return String(format: "%dh %02dm", h, m)
    }

    /// Idle threshold label: 5 → "5m", 60 → "1h", 90 → "1h 30m", 0.5 → "30s".
    public static func threshold(minutes: Double) -> String {
        let s = Int((minutes * 60).rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if sec > 0 || parts.isEmpty { parts.append("\(sec)s") }
        return parts.joined(separator: " ")
    }

    /// "1 project", "3 projects".
    public static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// Date formatting in the user's locale and time zone.
    public static let dates = DateFormats()

    /// Date and time in the user's locale, e.g. "9/24/26, 3:45 PM"; `nil` → "–".
    public static func dateTime(_ d: Date?) -> String { dates.dateTime(d) }

    /// Time of day in the user's locale, e.g. "3:45 PM" or "15:45".
    public static func time(_ d: Date) -> String { dates.time(d) }

    /// Weekday, day and month in the user's locale, e.g. "Thu, Sep 24".
    public static func dayLabel(_ d: Date) -> String { dates.day(d) }

    /// Locale-independent calendar day for machine-readable output, e.g. "2026-09-24".
    public static func dayKey(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// Locale-aware date strings. `Format.dates` follows the user's settings; tests pass a fixed locale.
public struct DateFormats: @unchecked Sendable {  // DateFormatter is thread-safe for formatting
    private let dateTimeFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    public init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        func make(_ configure: (DateFormatter) -> Void) -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            configure(f)
            return f
        }
        dateTimeFormatter = make { $0.dateStyle = .short; $0.timeStyle = .short }
        timeFormatter = make { $0.dateStyle = .none; $0.timeStyle = .short }
        dayFormatter = make { $0.setLocalizedDateFormatFromTemplate("EEEdMMM") }
    }

    public func dateTime(_ d: Date?) -> String {
        guard let d else { return "–" }
        return dateTimeFormatter.string(from: d)
    }

    public func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    public func day(_ d: Date) -> String { dayFormatter.string(from: d) }
}
