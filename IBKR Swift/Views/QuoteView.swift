//
//  QuoteView.swift
//  IBKR Swift
//

import Charts
import IbkrCore
import SwiftUI

struct QuoteView: View {
    @Environment(AppStore.self) private var store
    @State private var symbol = "AAPL"
    @State private var range = ChartRange.day
    @State private var interval = BarInterval.min5
    @AppStorage("chartStyle") private var style = PriceChart.Style.line
    /// The chart fills the pane; the symbol field and quote cards are hidden.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !expanded {
                HStack {
                    TextField("Symbol", text: $symbol)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit { store.watchQuote(symbol: symbol) }
                    Button("Watch") { store.watchQuote(symbol: symbol) }
                        .keyboardShortcut(.defaultAction)
                }
            }

            if let q = store.quote {
                if !expanded {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(q.symbol).font(.largeTitle.bold())
                        Text(q.last.formatted()).font(.largeTitle).monospacedDigit()
                        change(q)
                        if q.delayed { Pill(text: "DELAYED", color: .orange) }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        cell("Bid", q.bid.formatted(), q.bidSize).foregroundStyle(.red)
                        cell("Ask", q.ask.formatted(), q.askSize).foregroundStyle(.green)
                        cell("Close", q.close.formatted(), nil)
                        cell("Volume", q.volume.map(\.quantity) ?? "—", nil)
                    }
                    .frame(maxWidth: 700)
                    .monospacedDigit()
                }

                HStack(spacing: 16) {
                    if expanded {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(q.symbol).font(.title2.bold())
                            Text(q.last.formatted()).font(.title2).monospacedDigit()
                            change(q)
                        }
                    }
                    Picker("Range", selection: $range) {
                        ForEach(ChartRange.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 200)
                    Picker("Interval", selection: $interval) {
                        ForEach(range.intervals, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 150)
                    Spacer()
                    Picker("Style", selection: $style) {
                        Image(systemName: "chart.xyaxis.line").tag(PriceChart.Style.line)
                        Image(systemName: "chart.bar.xaxis").tag(PriceChart.Style.candles)
                    }
                    .frame(width: 90)
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(expanded ? "Collapse chart (Esc)" : "Expand chart")
                    .keyboardShortcut(expanded ? .cancelAction : nil)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: expanded ? .infinity : 700)
                .onChange(of: range) { _, range in
                    if !range.intervals.contains(interval) { interval = range.defaultInterval }
                }

                PriceChart(bars: store.history, series: store.historySeries, interval: interval, style: style,
                           loading: store.loadingHistory, loadingOlder: store.loadingOlderHistory,
                           needOlder: { Task { await store.loadOlderHistory() } })
                    .frame(maxWidth: expanded ? .infinity : 700, minHeight: 240,
                           maxHeight: expanded ? .infinity : 320)
                    .task(id: "\(q.symbol)|\(range)|\(interval)") {
                        // Skip the transient pair while a range change resets the interval.
                        guard range.intervals.contains(interval) else { return }
                        await store.loadHistory(symbol: q.symbol, range: range, interval: interval)
                    }
            }
            if !expanded { Spacer() }
        }
        .padding()
        .navigationTitle("Quote")
    }

    @ViewBuilder
    private func change(_ q: Quote) -> some View {
        if let last = q.last, let close = q.close, close > 0 {
            let diff = last - close
            Text("\(diff >= 0 ? "+" : "")\(diff.formatted(.number.precision(.fractionLength(2)))) (\((diff / close).formatted(.percent.precision(.fractionLength(2)))))")
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(diff >= 0 ? .green : .red)
        }
    }

    private func cell(_ label: String, _ value: String, _ size: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.title2.weight(.semibold))
                if let size { Text("× \(size.quantity)").foregroundStyle(.secondary) }
            }
        }
        .card()
    }
}

/// Close-price line or candlesticks for the loaded bars. The line is green or red by
/// the change over the range; each candle by its own open → close.
///
/// Bars are plotted by index, so nights and weekends leave no gaps. Only the bars in the
/// viewport are handed to Charts, which keeps panning and zooming cheap.
/// Input comes from `ChartInput`: drag or swipe sideways to pan; pinch, swipe vertically
/// or use the wheel to zoom (Shift-wheel pans). After a click, ← → pan, + − zoom, 0 resets.
struct PriceChart: View {
    enum Style: String {
        case line, candles
    }

    let bars: [PriceBar]
    /// Changes when `bars` is a new load rather than older bars prepended.
    let series: Int
    let interval: BarInterval
    let style: Style
    let loading: Bool
    let loadingOlder: Bool
    /// Called when the user moves near the oldest loaded bar.
    let needOlder: () -> Void

    /// Bars across the plot, and the index at its left edge.
    @State private var visible: Double = 0
    @State private var start: Double = 0
    /// The plot area within the chart, read from Charts for pointer anchoring.
    @State private var plot = CGRect.zero

    private static let minVisible: Double = 10

    var body: some View {
        let slice = visibleSlice
        let y = yDomain(slice)
        let ticks = timeTicks()
        Group {
            switch style {
            case .line: line(slice)
            case .candles: candles(slice)
            }
        }
        .chartXScale(domain: start - 0.5 ... start + max(visible, 1) - 0.5)
        .chartYScale(domain: y)
        .chartXAxis { timeAxis(ticks) }
        .chartYAxis { priceAxis(y) }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let frame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
                Color.clear.onChange(of: frame, initial: true) { plot = frame }
            }
        }
        // A plain overlay, not `chartOverlay`: Charts rebuilds that as the view changes,
        // which would replace the AppKit view mid-drag and end the drag.
        .overlay {
            ChartInput(
                pan: { pan(points: $0, width: plot.width) },
                zoom: { zoom(by: $0, anchor: anchor($1, in: plot)) },
                key: handle
            )
        }
        .overlay {
            if loading && bars.isEmpty {
                ProgressView()
            } else if bars.isEmpty {
                Text("No price history").foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topLeading) {
            if loadingOlder { ProgressView().controlSize(.small) }
        }
        .onChange(of: [series, bars.count], initial: true) { old, new in
            if old[0] == new[0] && new[1] > old[1] {
                // Older bars were prepended: shift so the same bars stay in view.
                setViewport(visible: visible, start: start + Double(new[1] - old[1]))
            } else {
                resetViewport()
            }
        }
        .card()
    }

    // MARK: Marks

    private func line(_ slice: ArraySlice<PriceBar>) -> some View {
        let up = (bars.last?.close ?? 0) >= (bars.first?.open ?? 0)
        let color: Color = up ? .green : .red
        let floor = yDomain(slice).lowerBound
        return Chart(slice.indices, id: \.self) { i in
            AreaMark(x: .value("Bar", Double(i)), yStart: .value("Floor", floor), yEnd: .value("Close", bars[i].close))
                .foregroundStyle(color.opacity(0.12))
            LineMark(x: .value("Bar", Double(i)), y: .value("Close", bars[i].close))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
    }

    private func candles(_ slice: ArraySlice<PriceBar>) -> some View {
        Chart(slice.indices, id: \.self) { i in
            let bar = bars[i]
            let color: Color = bar.close >= bar.open ? .green : .red
            let x = Double(i)
            RuleMark(x: .value("Bar", x), yStart: .value("Low", bar.low), yEnd: .value("High", bar.high))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(color)
            RectangleMark(
                xStart: .value("Start", x - 0.35),
                xEnd: .value("End", x + 0.35),
                yStart: .value("Open", bar.open),
                yEnd: .value("Close", bar.close)
            )
            .foregroundStyle(color)
        }
    }

    // MARK: Viewport

    /// Bars in view plus one on each side, so marks at the edges slide in and out.
    private var visibleSlice: ArraySlice<PriceBar> {
        guard !bars.isEmpty else { return [] }
        let lo = max(0, Int(start.rounded(.down)) - 1)
        let hi = min(bars.count, Int((start + visible).rounded(.up)) + 1)
        return lo < hi ? bars[lo..<hi] : []
    }

    /// Fits the prices in view, with a little headroom.
    private func yDomain(_ slice: ArraySlice<PriceBar>) -> ClosedRange<Double> {
        let lows = style == .line ? slice.map(\.close) : slice.map(\.low)
        let highs = style == .line ? slice.map(\.close) : slice.map(\.high)
        guard let lo = lows.min(), let hi = highs.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.05, hi * 0.0005)
        return (lo - pad)...(hi + pad)
    }

    private func setViewport(visible: Double, start: Double) {
        let count = Double(bars.count)
        let visible = min(max(visible, min(Self.minVisible, count)), count)
        self.visible = visible
        self.start = min(max(start, 0), count - visible)
    }

    private func resetViewport() {
        setViewport(visible: Double(bars.count), start: 0)
    }

    /// Zooms by `factor` (>1 = in), keeping the bar at `anchor` (0…1 across the plot) in place.
    private func zoom(by factor: Double, anchor: Double) {
        let pivot = start + visible * anchor
        let newVisible = visible / factor
        move(visible: newVisible, start: pivot - newVisible * anchor)
    }

    private func handle(_ key: ChartInput.Key) {
        switch key {
        case .left: move(visible: visible, start: start - visible * 0.1)
        case .right: move(visible: visible, start: start + visible * 0.1)
        case .zoomIn: zoom(by: 1.25, anchor: 0.5)
        case .zoomOut: zoom(by: 0.8, anchor: 0.5)
        case .reset: resetViewport()
        }
    }

    /// Moves the view with the pointer: dragging right reveals earlier bars.
    private func pan(points dx: CGFloat, width: CGFloat) {
        move(visible: visible, start: start - Double(dx / max(width, 1)) * visible)
    }

    /// A user pan/zoom: also asks for older bars when it heads into the past (pan back or
    /// zoom out) near, or past, the oldest one. The store paces the actual requests.
    private func move(visible: Double, start: Double) {
        let backwards = start < self.start || (start <= 0 && visible >= Double(bars.count))
        setViewport(visible: visible, start: start)
        if backwards && start < visible * 0.25 { needOlder() }
    }

    /// 0…1 across the plot area.
    private func anchor(_ x: CGFloat, in plot: CGRect) -> Double {
        min(max(Double((x - plot.minX) / max(plot.width, 1)), 0), 1)
    }

    // MARK: Axes

    private func timeAxis(_ ticks: [TimeTick]) -> some AxisContent {
        AxisMarks(values: ticks.map { Double($0.index) }) { value in
            AxisGridLine()
            AxisTick()
            if let i = value.as(Double.self), let tick = ticks.first(where: { $0.index == Int(i) }) {
                AxisValueLabel(tick.label, anchor: .top)
                    .font(tick.major ? .caption2.weight(.semibold) : .caption2)
            }
        }
    }

    private func priceAxis(_ y: ClosedRange<Double>) -> some AxisContent {
        // Cents when zoomed in on a narrow price band, whole dollars across a wide one.
        let decimals = y.upperBound - y.lowerBound < 20 ? 2 : 0
        return AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(decimals)))
        }
    }


    /// A labelled bar on the time axis. `major` marks a new day/month/year.
    struct TimeTick {
        let index: Int
        let label: String
        let major: Bool
    }

    /// Calendar steps for time-axis labels, finest first.
    private enum Step: CaseIterable {
        case min5, min15, min30, hour1, hour2, day1, day2, week1, month1, month3, month6, year1, year5

        var minutes: Int? {
            switch self {
            case .min5: 5
            case .min15: 15
            case .min30: 30
            case .hour1: 60
            case .hour2: 120
            default: nil
            }
        }
    }

    /// Labels the first bar of each calendar step in view, using the finest step that
    /// leaves ~90pt per label. Recomputed on every pan/zoom, so labels follow the view.
    private func timeTicks() -> [TimeTick] {
        let lo = max(0, Int(start.rounded(.up)))
        let hi = min(bars.count - 1, Int((start + visible - 1).rounded(.down)))
        guard lo <= hi else { return [] }
        let budget = max(2, Int(plot.width / 90))
        let cal = Calendar.current
        let dates = (max(0, lo - 1)...hi).map { Date(timeIntervalSince1970: TimeInterval(bars[$0].time)) }
        // dates[k] is bar lo - 1 + k when lo > 0, else bar k.
        let offset = lo > 0 ? 1 : 0
        // Calendar lookups are the costly part, so do them once per bar, not once per step.
        let parts = dates.map {
            cal.dateComponents([.year, .month, .day, .hour, .minute, .weekOfYear, .yearForWeekOfYear], from: $0)
        }

        func bucket(_ k: Int, _ step: Step) -> Int {
            let c = parts[k]
            let (y, m, day) = (c.year!, c.month!, c.day!)
            let dayKey = y * 10_000 + m * 100 + day
            if let minutes = step.minutes { return dayKey * 10_000 + (c.hour! * 60 + c.minute!) / minutes }
            switch step {
            case .day1: return dayKey
            // Local day number, paired up.
            case .day2: return Int((dates[k].timeIntervalSince1970 + Double(cal.timeZone.secondsFromGMT(for: dates[k]))) / 86_400) / 2
            case .week1: return c.yearForWeekOfYear! * 100 + c.weekOfYear!
            case .month1: return y * 100 + m
            case .month3: return y * 100 + (m - 1) / 3
            case .month6: return y * 100 + (m - 1) / 6
            case .year1: return y
            default: return y / 5
            }
        }

        // Bars (in view) that start a new bucket of `step`.
        func starts(_ step: Step) -> [Int] {
            var out: [Int] = []
            var previous = offset == 1 ? bucket(0, step) : nil
            for k in offset..<dates.count {
                let b = bucket(k, step)
                if let previous, b != previous { out.append(k) }
                previous = b
            }
            return out
        }

        let finest = Step.allCases.lazy.map { ($0, starts($0)) }.first { $0.1.count <= budget }
        guard let (step, ks) = finest else { return [] }
        return ks.map { k in
            let date = dates[k]
            let index = lo - offset + k
            let (c, p) = (parts[k], k > 0 ? parts[k - 1] : nil)
            let newYear = p.map { $0.year != c.year } ?? false
            let newMonth = newYear || p.map { $0.month != c.month } ?? false
            let newDay = newMonth || p.map { $0.day != c.day } ?? false
            let label: String
            let major: Bool
            switch step {
            case .min5, .min15, .min30, .hour1, .hour2:
                major = newDay
                label = newDay ? date.formatted(.dateTime.month(.abbreviated).day())
                               : date.formatted(.dateTime.hour().minute())
            case .day1, .day2, .week1:
                major = newMonth
                label = newYear ? date.formatted(.dateTime.year())
                                : date.formatted(.dateTime.month(.abbreviated).day())
            case .month1, .month3, .month6:
                major = newYear
                label = newYear ? date.formatted(.dateTime.year()) : date.formatted(.dateTime.month(.abbreviated))
            case .year1, .year5:
                major = true
                label = date.formatted(.dateTime.year())
            }
            return TimeTick(index: index, label: label, major: major)
        }
    }
}

extension ChartRange: @retroactive CaseIterable {
    public static let allCases: [ChartRange] = [.day, .week, .month, .year]

    var label: String {
        switch self {
        case .day: "1D"
        case .week: "1W"
        case .month: "1M"
        case .year: "1Y"
        }
    }

    /// Bar sizes worth showing for this range (IB also caps bars per request).
    var intervals: [BarInterval] {
        switch self {
        case .day: [.min1, .min2, .min5]
        case .week: [.min15, .hour1, .hour4]
        case .month: [.hour1, .hour4, .day1]
        case .year: [.day1]
        }
    }

    var defaultInterval: BarInterval {
        switch self {
        case .day: .min5
        case .week: .min15
        case .month, .year: .day1
        }
    }
}

extension BarInterval {
    var label: String {
        switch self {
        case .min1: "1m"
        case .min2: "2m"
        case .min5: "5m"
        case .min15: "15m"
        case .hour1: "1h"
        case .hour4: "4h"
        case .day1: "1D"
        }
    }
}
