import Foundation

/// Indices whose candle centers are inside the plot. Excludes the extra bars
/// rendered beyond each edge to make panning smooth.
enum ChartViewport {
    static func indices(count: Int, start: Double, visible: Double) -> Range<Int> {
        guard count > 0, visible > 0 else { return 0..<0 }
        let lower = min(count, max(0, Int(ceil(start - 0.5))))
        let upper = min(count, max(lower, Int(floor(start + visible - 0.5)) + 1))
        return lower..<upper
    }
}

enum ChartSessionClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func startOfDay(_ date: Date) -> Int64 {
        Int64(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    /// At the live edge, premarket can belong to today even before today's first
    /// RTH chart bar. Panning back selects the date at the right edge of the plot.
    static func sessionTime(lastVisible: Int64, atLatest: Bool, now: Date = .now) -> Int64 {
        let barDay = startOfDay(Date(timeIntervalSince1970: TimeInterval(lastVisible)))
        let weekday = calendar.component(.weekday, from: now)
        return atLatest && (2...6).contains(weekday) ? max(barDay, startOfDay(now)) : barDay
    }

    static func label(_ time: Int64) -> String {
        var format = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        format.timeZone = calendar.timeZone
        return Date(timeIntervalSince1970: TimeInterval(time)).formatted(format)
    }
}
