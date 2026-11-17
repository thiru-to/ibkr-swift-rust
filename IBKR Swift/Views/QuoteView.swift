//
//  QuoteView.swift
//  IBKR Swift
//

import Charts
import IbkrCore
import SwiftUI

struct QuoteView: View {
    @Environment(AppStore.self) private var store
    @State private var searching = false
    @State private var searchText = ""
    @State private var range = ChartRange.day
    @State private var interval = BarInterval.min5
    @AppStorage("chartStyle") private var style = PriceChart.Style.line
    @AppStorage("quoteChartIndicators") private var indicators = 0
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                QuoteMarketHeader(searching: $searching, searchText: $searchText)
                if store.quoteInstrument != nil {
                    chartControls
                    QuoteHistoryChart(range: range, interval: interval, style: style, indicators: indicators)
                    Text("Scroll to zoom · Shift-scroll to pan · Click chart for keyboard controls")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    WorkspaceEmptyState(title: "Find your next instrument", icon: "magnifyingglass",
                        description: "Search stocks, ETFs, indexes, and options. You can also start typing anywhere on this screen.", tint: .blue)
                }
            }
            // Keep wrapped empty-state text and chart content from inflating the
            // window's minimum size during NavigationSplitView's sizing pass.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            QuoteTradePanel()
                .frame(width: 260)
                .padding(16)
                .background(AppTheme.surface, in: .rect(cornerRadius: AppTheme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.cardRadius).strokeBorder(AppTheme.border).allowsHitTesting(false))
        }
        .padding(AppTheme.pagePadding)
        .navigationTitle("Quote")
        .background(QuoteKeyboardInput(isSearching: searching) { characters in
            if searching { searchText += characters } else { searchText = characters }
            searching = true
        })
        .sheet(isPresented: $searching) {
            InstrumentSearchView(query: $searchText) { instrument in
                store.watchInstrument(instrument)
                searching = false
            }
        }
    }

    private var chartControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Interval", selection: $interval) {
                    ForEach(range.intervals, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Style", selection: $style) {
                    Image(systemName: "chart.xyaxis.line").help("Line chart").tag(PriceChart.Style.line)
                    Image(systemName: "chart.bar.xaxis").help("Candlestick chart").tag(PriceChart.Style.candles)
                }.frame(width: 80)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .onChange(of: range) { _, range in
                if !range.intervals.contains(interval) { interval = range.defaultInterval }
            }
            ChartIndicatorMenu(selection: $indicators).controlSize(.small)
        }
    }
}

/// Quote ticks update this small header independently of the chart and its controls.
private struct QuoteMarketHeader: View {
    @Environment(AppStore.self) private var store
    @Binding var searching: Bool
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { searchText = ""; searching = true } label: {
                    Label(store.quoteInstrument?.symbol ?? "Search instruments", systemImage: "magnifyingglass")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered).controlSize(.large)
                if let q = store.quote {
                    Text(q.last.formatted())
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    change(q)
                    if q.delayed { Pill(text: "DELAYED", color: .orange) }
                }
                Spacer(minLength: 0)
            }
            if let instrument = store.quoteInstrument {
                Text("\(instrument.name) · \(instrument.primaryExchange) · \(instrument.currency)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(instrument.name)
            }
            if let q = store.quote {
                HStack(spacing: 20) {
                    metric("Bid", value: q.bid.formatted(), tint: .red)
                    metric("Ask", value: q.ask.formatted(), tint: .green)
                    metric("Volume", value: q.volume.map(\.quantity) ?? "—", tint: .primary)
                }
            }
        }
        .monospacedDigit()
        .card(tint: .blue)
    }

    private func metric(_ title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).foregroundStyle(tint)
        }.font(.callout)
    }

    @ViewBuilder
    private func change(_ q: Quote) -> some View {
        if let last = q.last, let close = q.close, close > 0 {
            let diff = last - close
            Text("\(diff >= 0 ? "+" : "")\(diff.formatted(.number.precision(.fractionLength(2)))) (\((diff / close).formatted(.percent.precision(.fractionLength(2)))))")
                .font(.callout.weight(.medium))
                .foregroundStyle(diff >= 0 ? .green : .red)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

private struct QuoteHistoryChart: View {
    @Environment(AppStore.self) private var store
    let range: ChartRange
    let interval: BarInterval
    let style: PriceChart.Style
    let indicators: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PriceChart(bars: store.history, series: store.historySeries, interval: interval, style: style,
                       instrument: store.quoteInstrument, indicators: indicators,
                       loading: store.loadingHistory, loadingOlder: store.loadingOlderHistory,
                       needOlder: { Task { await store.loadOlderHistory() } })
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            if let error = store.historyError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(store.quoteInstrument?.contractId ?? 0)|\(range)|\(interval)") {
            guard range.intervals.contains(interval), let instrument = store.quoteInstrument else { return }
            await store.loadHistory(instrument: instrument, range: range, interval: interval)
        }
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
    @Environment(AppStore.self) private var store
    enum Style: String {
        case line, candles
    }

    let bars: [PriceBar]
    /// Changes when `bars` is a new load rather than older bars prepended.
    let series: Int
    let interval: BarInterval
    let style: Style
    let instrument: Instrument?
    let indicators: Int
    let loading: Bool
    let loadingOlder: Bool
    /// Called when the user moves near the oldest loaded bar.
    let needOlder: () -> Void

    /// Bars across the plot, and the index at its left edge.
    @State private var visible: Double = 0
    @State private var start: Double = 0
    /// The plot area within the chart, read from Charts for pointer anchoring.
    @State private var plot = CGRect.zero
    @State private var levels: ChartSessionLevels?
    @State private var levelsKey: String?
    @State private var levelsError: String?
    @State private var loadingLevels = false
    @State private var indicatorNow = Date.now

    private static let minVisible: Double = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if indicators != 0 { indicatorLegend }
            pricePlot
        }
        .card()
        .task(id: sessionRequestKey) { await loadLevels() }
    }

    private var pricePlot: some View {
        let slice = visibleSlice
        let lines = indicatorLines
        let y = yDomain(slice, levels: lines)
        let ticks = timeTicks()
        return Group {
            switch style {
            case .line: line(slice, levels: lines, floor: y.lowerBound)
            case .candles: candles(slice, levels: lines)
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
                ZStack(alignment: .topLeading) {
                    Color.clear.onChange(of: frame, initial: true) { plot = frame }
                    ForEach(levelLabels(lines, positions: lines.map { proxy.position(forY: $0.price) ?? 0 }, height: frame.height), id: \.level.id) { item in
                        Text("\(item.level.id)  \(item.level.priceLabel)")
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(item.level.color)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                            .frame(width: 132, alignment: .trailing)
                            .position(x: frame.maxX - 70, y: frame.minY + item.y)
                    }
                }.allowsHitTesting(false)
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
    }

    // MARK: Marks

    private func line(_ slice: ArraySlice<PriceBar>, levels: [ChartLevel], floor: Double) -> some View {
        let up = (bars.last?.close ?? 0) >= (bars.first?.open ?? 0)
        let color: Color = up ? .green : .red
        return Chart {
            ForEach(slice.indices, id: \.self) { i in
                AreaMark(x: .value("Bar", Double(i)), yStart: .value("Floor", floor), yEnd: .value("Close", bars[i].close))
                    .foregroundStyle(color.opacity(0.12))
                LineMark(x: .value("Bar", Double(i)), y: .value("Close", bars[i].close))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            indicatorMarks(levels)
        }
    }

    private func candles(_ slice: ArraySlice<PriceBar>, levels: [ChartLevel]) -> some View {
        Chart {
            ForEach(slice.indices, id: \.self) { i in
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
            indicatorMarks(levels)
        }
    }

    @ChartContentBuilder
    private func indicatorMarks(_ levels: [ChartLevel]) -> some ChartContent {
        ForEach(levels) { level in
            RuleMark(y: .value(level.id, level.price))
                .foregroundStyle(level.color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: level.low ? [3, 3] : [8, 3]))
        }
    }

    // MARK: Indicators

    private var selectedIndicators: [QuoteChartIndicator] {
        QuoteChartIndicator.allCases.filter { $0.enabled(in: indicators) }
    }

    private var viewportIndices: Range<Int> {
        ChartViewport.indices(count: bars.count, start: start, visible: visible)
    }

    private var sessionTime: Int64? {
        guard let last = viewportIndices.last else { return nil }
        return ChartSessionClock.sessionTime(lastVisible: bars[last].time,
            atLatest: start + visible >= Double(bars.count) - 0.5, now: indicatorNow)
    }

    private var sessionRequestKey: String? {
        guard selectedIndicators.contains(where: { $0 != .visible }),
              let instrument, let sessionTime else { return nil }
        return "\(instrument.contractId)|\(sessionTime)"
    }

    private var currentLevels: ChartSessionLevels? {
        levelsKey == sessionRequestKey ? levels : nil
    }

    private var visibleRange: ChartPriceRange? {
        var low = Double.infinity
        var high = -Double.infinity
        for i in viewportIndices {
            let bar = bars[i]
            guard bar.low.isFinite, bar.high.isFinite else { continue }
            low = min(low, bar.low)
            high = max(high, bar.high)
        }
        guard low.isFinite, high.isFinite else { return nil }
        return ChartPriceRange(high: high, low: low)
    }

    private func indicatorRange(_ indicator: QuoteChartIndicator) -> ChartPriceRange? {
        indicator == .visible ? visibleRange : indicator.range(in: currentLevels)
    }

    private var indicatorLines: [ChartLevel] {
        selectedIndicators.flatMap { indicator in
            indicatorRange(indicator).map { indicator.lines($0) } ?? []
        }
    }

    private var indicatorLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sessionTime, sessionRequestKey != nil {
                HStack(spacing: 6) {
                    Text("Session levels · \(ChartSessionClock.label(sessionTime)) · New York")
                        .help("Uses the session at the right edge of the chart. At the latest bar, uses today on weekdays, including premarket.")
                    if loadingLevels { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(selectedIndicators) { indicator in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(indicator.shortTitle).fontWeight(.medium).foregroundStyle(indicator.color)
                        if let range = indicatorRange(indicator) {
                            Text("H \(range.high.formatted(.number.precision(.fractionLength(2...4))))  L \(range.low.formatted(.number.precision(.fractionLength(2...4))))")
                                .monospacedDigit()
                            if indicator == .previousDay, let date = currentLevels?.previousSessionDate {
                                Text(date).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(indicatorStatus(indicator)).foregroundStyle(.secondary)
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let error = levelsError, sessionRequestKey != nil {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let levels = currentLevels {
                if let error = levels.intradayError, selectedIndicators.contains(where: { $0 != .visible && $0 != .previousDay }) {
                    Text("ORB / premarket: \(error)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let error = levels.previousDayError, QuoteChartIndicator.previousDay.enabled(in: indicators) {
                    Text("Previous session: \(error)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if QuoteChartIndicator.premarket.enabled(in: indicators),
                   ChartSessionClock.calendar.component(.hour, from: indicatorNow) < 10,
                   sessionTime == ChartSessionClock.startOfDay(indicatorNow) {
                    Text("Premarket develops until 9:30. ORB appears after 9:45 / 10:00. Refreshes every minute.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func indicatorStatus(_ indicator: QuoteChartIndicator) -> String {
        if indicator == .visible { return "No bars in view" }
        if loadingLevels || levelsKey != sessionRequestKey { return "Loading…" }
        guard let levels = currentLevels else { return "Unavailable" }
        if indicator == .orb15 || indicator == .orb30,
           let sessionTime {
            let end = sessionTime + Int64((indicator == .orb15 ? 9 * 60 + 45 : 10 * 60) * 60)
            if levels.asOf < end { return indicator == .orb15 ? "Waiting for 9:45 AM NY" : "Waiting for 10:00 AM NY" }
        }
        return "No data for this session"
    }

    private func loadLevels() async {
        levels = nil
        levelsError = nil
        levelsKey = nil
        loadingLevels = false
        guard let key = sessionRequestKey, let instrument, let sessionTime else { return }
        // Panning can cross many dates; only request once the view settles.
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        while !Task.isCancelled {
            loadingLevels = true
            do {
                let loaded = try await store.chartSessionLevels(instrument: instrument, sessionTime: sessionTime)
                guard !Task.isCancelled else { return }
                levels = loaded
                levelsKey = key
                levelsError = nil
            } catch {
                guard !Task.isCancelled else { return }
                levelsKey = key
                levelsError = (error as? ActionError)?.message ?? error.localizedDescription
            }
            loadingLevels = false
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            indicatorNow = .now
        }
    }

    /// Keep nearby labels legible, including when multiple indicators share a price.
    private func levelLabels(_ levels: [ChartLevel], positions: [CGFloat], height: CGFloat) -> [(level: ChartLevel, y: CGFloat)] {
        guard height > 0 else { return [] }
        let gap = min(16.0, max(0, (height - 16) / CGFloat(max(levels.count - 1, 1))))
        var placed: [(level: ChartLevel, y: CGFloat)] = zip(levels, positions).map { level, position in
            (level: level, y: position)
        }
        placed.sort { a, b in
            if a.y == b.y { return a.level.id < b.level.id }
            return a.y < b.y
        }
        for i in placed.indices {
            placed[i].y = max(placed[i].y, i == 0 ? 8 : placed[i - 1].y + gap)
        }
        for i in placed.indices.reversed() {
            placed[i].y = min(placed[i].y, i == placed.count - 1 ? height - 8 : placed[i + 1].y - gap)
        }
        return placed
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
    private func yDomain(_ slice: ArraySlice<PriceBar>, levels: [ChartLevel]) -> ClosedRange<Double> {
        var lo = Double.infinity
        var hi = -Double.infinity
        for bar in slice {
            let low = style == .line ? bar.close : bar.low
            let high = style == .line ? bar.close : bar.high
            if low.isFinite { lo = min(lo, low) }
            if high.isFinite { hi = max(hi, high) }
        }
        for level in levels where level.price.isFinite {
            lo = min(lo, level.price)
            hi = max(hi, level.price)
        }
        guard lo.isFinite, hi.isFinite, lo <= hi else { return 0...1 }
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
