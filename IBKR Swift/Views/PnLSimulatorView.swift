//
//  PnLSimulatorView.swift
//  IBKR Swift
//
//  What-if P/L for the option on the strategy ticket: P/L against the underlying's price
//  at a chosen time and at expiry, with the ticket's trigger, take-profit and stop drawn
//  in. Prices come from Black-Scholes (OptionMath) at the option's implied volatility.
//  It's an estimate only; nothing here places or changes orders.
//

import Charts
import IbkrCore
import SwiftUI

/// The ticket selections the simulator needs.
struct SimulationInput: Equatable {
    var option: OptionSpec
    var quantity: Double
    var multiplier: Double
    /// Entry happens when the underlying reaches this; nil = buy now.
    var triggerPrice: Double?
    var takeProfit: Target?
    var stopLoss: Target?
    /// "HH:MM" US/Eastern today, when the position is closed regardless.
    var closeAt: String?
}

struct PnLSimulatorView: View {
    @Environment(AppStore.self) private var store
    let input: SimulationInput?

    /// User overrides; nil means "use the market / the default".
    @State private var volPercent: Double?
    @State private var hoursAhead: Double?

    var body: some View {
        Group {
            if let input, let model = model(input) {
                content(input, model)
            } else {
                ContentUnavailableView("P/L Simulation", systemImage: "chart.xyaxis.line",
                                       description: Text(placeholder))
            }
        }
        .onChange(of: input?.option) {
            volPercent = nil
            hoursAhead = nil
        }
    }

    private var placeholder: String {
        guard input != nil else { return "Pick an expiry and strike on the ticket." }
        return "Waiting for quotes on \(input!.option.symbol) and the option."
    }

    // MARK: Model

    /// Everything derived from the inputs and quotes, at one instant.
    struct Model {
        let call: Bool
        let strike: Double
        let spot: Double
        /// Underlying price at entry: the trigger, or now.
        let entrySpot: Double
        /// Premium per share paid at entry.
        let entry: Double
        /// Shares-equivalent: contracts × multiplier.
        let size: Double
        let years: Double
        /// From the option's quote; nil if it couldn't be solved.
        let marketVol: Double?
        let vol: Double
        let evalHours: Double
        let maxHours: Double
        let evalDate: Date
        let takeProfit: Double?
        let stopLoss: Double?
        let delayed: Bool

        var cost: Double { entry * size }
        var evalYears: Double { max(years - evalHours * 3600 / OptionMath.secondsPerYear, 0) }
        var breakeven: Double { call ? strike + entry : strike - entry }

        func pnl(at spot: Double, years: Double) -> Double {
            (OptionMath.price(call: call, spot: spot, strike: strike, years: years, vol: vol) - entry) * size
        }

        /// Spread of prices to plot: ~3 standard deviations to expiry, and always the
        /// strike, trigger and breakeven.
        var priceRange: ClosedRange<Double> {
            let move = max(spot * vol * years.squareRoot() * 3, spot * 0.02)
            let points = [spot - move, spot + move, strike, entrySpot, breakeven]
            let lo = points.min()!, hi = points.max()!
            let pad = (hi - lo) * 0.05
            return max(lo - pad, 0.01)...(hi + pad)
        }

        /// Underlying price where the curve at the evaluation time first reaches `pnl`
        /// moving away from the entry price toward profit (TP) or loss (stop).
        func spot(reaching pnl: Double, samples: [(s: Double, now: Double)]) -> Double? {
            let towardHigher = (pnl > 0) == call
            let ordered = towardHigher ? samples.filter { $0.s >= entrySpot } : samples.filter { $0.s <= entrySpot }.reversed()
            var previous: (s: Double, now: Double)?
            for p in ordered {
                if let q = previous, (q.now - pnl) * (p.now - pnl) <= 0, q.now != p.now {
                    return q.s + (pnl - q.now) / (p.now - q.now) * (p.s - q.s)
                }
                previous = p
            }
            return nil
        }

        var chanceOfProfit: Double {
            OptionMath.probability(above: call, level: breakeven, spot: entrySpot, years: years, vol: vol)
        }
    }

    private func model(_ input: SimulationInput) -> Model? {
        let o = input.option
        let call = o.right == .call
        guard let spot = store.underlyingQuote?.last ?? store.underlyingQuote?.close,
              let expiry = Eastern.date(o.expiry, hour: 16, minute: 0) else { return nil }
        let now = Date.now
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let years = seconds / OptionMath.secondsPerYear

        let q = store.optionQuote
        let mid = q.flatMap { q in q.bid.flatMap { b in q.ask.map { (b + $0) / 2 } } }
        guard let marketPremium = mid ?? q?.last ?? q?.ask else { return nil }
        let marketVol = OptionMath.impliedVol(call: call, premium: marketPremium, spot: spot, strike: o.strike, years: years)
        guard let vol = volPercent.map({ $0 / 100 }) ?? marketVol else { return nil }

        // A market buy pays the ask now; on a trigger, the theoretical price there plus half the spread.
        let halfSpread = q.flatMap { q in q.bid.flatMap { b in q.ask.map { ($0 - b) / 2 } } } ?? 0
        let entrySpot = input.triggerPrice ?? spot
        let entry = input.triggerPrice.map {
            OptionMath.price(call: call, spot: $0, strike: o.strike, years: years, vol: vol) + halfSpread
        } ?? q?.ask ?? marketPremium
        guard entry > 0 else { return nil }

        let size = input.quantity * input.multiplier
        let maxHours = seconds / 3600
        // Default to the close-out time when there is one (it's when the position is sold).
        let closeHours = input.closeAt.flatMap { Eastern.today(at: $0) }.map { $0.timeIntervalSince(now) / 3600 }
        let defaultHours = closeHours.map { min(max($0, 0), maxHours) } ?? 0
        let evalHours = min(hoursAhead ?? defaultHours, maxHours)

        func exit(_ target: Target?, sign: Double) -> Double? {
            switch target {
            case .percent(let v): sign * entry * v / 100 * size
            case .dollars(let v): sign * v
            case nil: nil
            }
        }

        return Model(
            call: call, strike: o.strike, spot: spot, entrySpot: entrySpot, entry: entry, size: size,
            years: years, marketVol: marketVol, vol: vol, evalHours: evalHours, maxHours: maxHours,
            evalDate: now.addingTimeInterval(evalHours * 3600),
            takeProfit: exit(input.takeProfit, sign: 1), stopLoss: exit(input.stopLoss, sign: -1),
            delayed: (store.underlyingQuote?.delayed ?? false) || (q?.delayed ?? false)
        )
    }

    // MARK: Views

    private func content(_ input: SimulationInput, _ m: Model) -> some View {
        let range = m.priceRange
        let step = (range.upperBound - range.lowerBound) / 200
        let samples = stride(from: range.lowerBound, through: range.upperBound, by: step).map {
            (s: $0, now: m.pnl(at: $0, years: m.evalYears), expiry: m.pnl(at: $0, years: 0))
        }
        let evalName = "At \(Eastern.timeLabel(m.evalDate))"

        return VStack(alignment: .leading, spacing: 12) {
            SimulationResults(input: input, model: m, samples: samples, evalName: evalName)
            controls(m)
        }
        .padding(AppTheme.pagePadding)
        .monospacedDigit()
    }

    private func controls(_ m: Model) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Time")
                Slider(value: Binding(get: { m.evalHours }, set: { hoursAhead = $0 }), in: 0...max(m.maxHours, 0.01))
                Text(Eastern.timeLabel(m.evalDate)).frame(width: 150, alignment: .leading)
                Button("Reset") { hoursAhead = nil }.disabled(hoursAhead == nil)
            }
            GridRow {
                Text("IV")
                Slider(value: Binding(get: { m.vol * 100 }, set: { volPercent = $0 }),
                       in: 1...max(150, (m.marketVol ?? 0) * 300))
                Text(m.marketVol.map { "market \($0.formatted(.percent.precision(.fractionLength(1))))" } ?? "no market IV")
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Button("Reset") { volPercent = nil }.disabled(volPercent == nil || m.marketVol == nil)
            }
        }
        .controlSize(.small)
    }
}

/// Pointer movement stays inside the results view. IV solving and curve sampling
/// happen in the parent only when quotes, ticket inputs, or simulation controls change.
private struct SimulationResults: View {
    private typealias Model = PnLSimulatorView.Model
    let input: SimulationInput
    let model: PnLSimulatorView.Model
    let samples: [(s: Double, now: Double, expiry: Double)]
    let evalName: String
    @State private var hoverSpot: Double?

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("P/L Simulation").font(.headline)
                Text("\(Int(input.quantity))× \(input.option.symbol) \(input.option.strike.formatted()) \(m.call ? "C" : "P")")
                    .foregroundStyle(.secondary)
                if m.delayed { Pill(text: "DELAYED", color: .orange) }
                Spacer()
                Text("Estimate").font(.caption).foregroundStyle(.secondary)
                    .help("Black-Scholes at one volatility, no dividends, \(OptionMath.riskFreeRate.formatted(.percent)) rate. Real fills, skew and gaps differ.")
            }

            stats(m, samples: samples.map { (s: $0.s, now: $0.now) })

            chart(m, samples: samples, evalName: evalName)
                .frame(minHeight: 220)

        }
    }

    private func stats(_ m: Model, samples: [(s: Double, now: Double)]) -> some View {
        let tpSpot = m.takeProfit.flatMap { m.spot(reaching: $0, samples: samples) }
        let slSpot = m.stopLoss.flatMap { m.spot(reaching: $0, samples: samples) }
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                stat("Cost (max loss)", m.cost.formatted(.currency(code: "USD")))
                stat("Entry premium", m.entry.formatted(.number.precision(.fractionLength(2))))
                stat("Breakeven at expiry", m.breakeven.formatted(.number.precision(.fractionLength(2))))
                stat("Chance of profit at expiry", m.chanceOfProfit.formatted(.percent.precision(.fractionLength(0))))
            }
            GridRow {
                stat("Take profit", exitText(m.takeProfit, spot: tpSpot), tint: .green)
                stat("Stop", exitText(m.stopLoss, spot: slSpot), tint: .red)
                stat("IV", m.vol.formatted(.percent.precision(.fractionLength(1))))
                stat("Hover", hoverText(m))
            }
        }
    }

    private func exitText(_ pnl: Double?, spot: Double?) -> String {
        guard let pnl else { return "off" }
        let money = pnl.formatted(.currency(code: "USD").sign(strategy: .always()))
        return spot.map { "\(money) @ \($0.formatted(.number.precision(.fractionLength(2))))" } ?? "\(money) (not in range)"
    }

    private func hoverText(_ m: Model) -> String {
        guard let s = hoverSpot else { return "—" }
        let now = m.pnl(at: s, years: m.evalYears)
        return "\(s.formatted(.number.precision(.fractionLength(2)))): \(now.formatted(.currency(code: "USD").sign(strategy: .always())))"
    }

    private func stat(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(tint)
        }
    }

    private func chart(_ m: Model, samples: [(s: Double, now: Double, expiry: Double)], evalName: String) -> some View {
        Chart {
            ForEach(samples, id: \.s) { p in
                LineMark(x: .value("Price", p.s), y: .value("P/L", p.expiry), series: .value("Curve", "At expiry"))
                    .foregroundStyle(by: .value("Curve", "At expiry"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                LineMark(x: .value("Price", p.s), y: .value("P/L", p.now), series: .value("Curve", evalName))
                    .foregroundStyle(by: .value("Curve", evalName))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.6))
            if let tp = m.takeProfit {
                RuleMark(y: .value("Take profit", tp))
                    .foregroundStyle(.green.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .annotation(position: .top, alignment: .leading) { tag("Take profit", .green) }
            }
            if let sl = m.stopLoss {
                RuleMark(y: .value("Stop", sl))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .annotation(position: .bottom, alignment: .leading) { tag("Stop", .red) }
            }
            RuleMark(x: .value("Now", m.spot))
                .foregroundStyle(.blue.opacity(0.6))
                .annotation(position: .top) { tag("Now", .blue) }
            if m.entrySpot != m.spot {
                RuleMark(x: .value("Trigger", m.entrySpot))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top) { tag("Trigger", .orange) }
            }
            if let s = hoverSpot {
                RuleMark(x: .value("Hover", s)).foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("Price", s), y: .value("P/L", m.pnl(at: s, years: m.evalYears)))
                    .foregroundStyle(.primary)
            }
        }
        .chartForegroundStyleScale(["At expiry": Color.secondary, evalName: Color.accentColor])
        .chartXScale(domain: m.priceRange)
        .chartXAxisLabel("\(input.option.symbol) price")
        .chartYAxisLabel("P/L")
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(v.formatted(.currency(code: "USD").precision(.fractionLength(0)))) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase {
                            hoverSpot = proxy.value(atX: p.x - origin.x, as: Double.self)
                        } else {
                            hoverSpot = nil
                        }
                    }
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
    }

}
