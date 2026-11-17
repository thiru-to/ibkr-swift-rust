// Run with:
// xcrun swiftc 'IBKR Swift/Views/ChartViewport.swift' scripts/test-chart-viewport.swift -o /tmp/test-chart-viewport
// /tmp/test-chart-viewport
import Foundation

@main
struct ChartViewportTests {
    static func main() {
        // View high/low must exclude the padded rendering bars and follow fractional pans.
        assert(ChartViewport.indices(count: 100, start: 20, visible: 10) == 20..<30)
        assert(ChartViewport.indices(count: 100, start: 20.6, visible: 10) == 21..<31)
        assert(ChartViewport.indices(count: 100, start: 20.4, visible: 10) == 20..<30)
        assert(ChartViewport.indices(count: 100, start: 0, visible: 100) == 0..<100)
        assert(ChartViewport.indices(count: 0, start: 0, visible: 10).isEmpty)
        assert(ChartViewport.indices(count: 100, start: 0, visible: 0).isEmpty)

        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        func time(_ text: String) -> Int64 { Int64(date(text).timeIntervalSince1970) }
        let friday = time("2026-11-13T20:00:00Z")
        let mondayPremarket = date("2026-11-16T13:00:00Z")
        assert(ChartSessionClock.sessionTime(lastVisible: friday, atLatest: true, now: mondayPremarket)
               == time("2026-11-16T05:00:00Z"))
        assert(ChartSessionClock.sessionTime(lastVisible: friday, atLatest: false, now: mondayPremarket)
               == time("2026-11-13T05:00:00Z"))
        assert(ChartSessionClock.sessionTime(lastVisible: friday, atLatest: true, now: date("2026-11-15T13:00:00Z"))
               == time("2026-11-13T05:00:00Z"))
        assert(ChartSessionClock.startOfDay(date("2026-07-06T15:00:00Z")) == time("2026-07-06T04:00:00Z"))
        assert(ChartSessionClock.startOfDay(date("2026-11-17T02:00:00Z")) == time("2026-11-16T05:00:00Z"))
        print("Chart viewport and New York session checks passed")
    }
}
