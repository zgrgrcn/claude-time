import Foundation

/// A contiguous stretch of activity: consecutive timestamps no further apart than the idle threshold.
public struct Block: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
}

public struct TimeWindows: Sendable {
    public let now: Double
    public let todayStart: Double
    public let weekStart: Double
    public let monthStart: Double

    /// Calendar used everywhere: the user's current calendar with weeks starting on Monday.
    public static var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    public init(now: Date = Date(), calendar: Calendar = TimeWindows.calendar) {
        self.now = now.timeIntervalSince1970
        todayStart = calendar.startOfDay(for: now).timeIntervalSince1970
        weekStart = (calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now).timeIntervalSince1970
        monthStart = (calendar.dateInterval(of: .month, for: now)?.start ?? now).timeIntervalSince1970
    }
}

public struct Stats: Sendable, Equatable {
    public var today: Double = 0
    public var week: Double = 0
    public var month: Double = 0
    public var total: Double = 0
    public var blocks: Int = 0
    public var firstSeen: Date?
    public var lastSeen: Date?
}

public struct DayStat: Sendable, Identifiable, Equatable {
    public var day: Date
    public var seconds: Double
    public var id: Date { day }
}

public enum Activity {
    /// Splits sorted timestamps into blocks; a gap larger than `idle` (seconds) starts a new block.
    public static func blocks(_ ts: [Double], idle: Double) -> [Block] {
        guard let first = ts.first else { return [] }
        var out: [Block] = []
        var start = first, prev = first
        for t in ts.dropFirst() {
            if t - prev > idle { out.append(Block(start: start, end: prev)); start = t }
            prev = t
        }
        out.append(Block(start: start, end: prev))
        return out
    }

    /// Seconds of activity inside `[from, to)`.
    public static func seconds(_ blocks: [Block], from: Double, to: Double) -> Double {
        var s = 0.0
        for b in blocks {
            let lo = max(b.start, from), hi = min(b.end, to)
            if hi > lo { s += hi - lo }
        }
        return s
    }

    public static func stats(_ ts: [Double], idle: Double, windows w: TimeWindows) -> Stats {
        let b = blocks(ts, idle: idle)
        let far = Double.greatestFiniteMagnitude
        return Stats(
            today: seconds(b, from: w.todayStart, to: far),
            week: seconds(b, from: w.weekStart, to: far),
            month: seconds(b, from: w.monthStart, to: far),
            total: seconds(b, from: -far, to: far),
            blocks: b.count,
            firstSeen: ts.first.map { Date(timeIntervalSince1970: $0) },
            lastSeen: ts.last.map { Date(timeIntervalSince1970: $0) })
    }

    /// Per-day activity for the last `days` days, oldest first (today last).
    public static func daily(_ ts: [Double], idle: Double, days: Int,
                             now: Date = Date(), calendar: Calendar = TimeWindows.calendar) -> [DayStat] {
        let b = blocks(ts, idle: idle)
        var out: [DayStat] = []
        let today = calendar.startOfDay(for: now)
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -i, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            out.append(DayStat(day: day, seconds: seconds(b, from: day.timeIntervalSince1970, to: next.timeIntervalSince1970)))
        }
        return out
    }

    /// Union of all projects' timestamps — use for a grand total so parallel sessions
    /// in different projects are not double counted.
    public static func merged(_ projects: [Project]) -> [Double] {
        var all = projects.flatMap(\.timestamps)
        all.sort()
        return TranscriptStore.dedupe(all)
    }
}
