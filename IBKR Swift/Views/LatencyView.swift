//
//  LatencyView.swift
//  IBKR Swift
//
//  Fill latency of strategy entries (option market buys), timed in the app as each IB
//  event arrived (`latency.rs`). IB's own timestamps are whole seconds, so these are the
//  most precise numbers available: microsecond clock, shown in milliseconds.
//

import IbkrCore
import SwiftUI

extension Optional where Wrapped == Double {
    /// "412.3 ms", or "—".
    var ms: String {
        guard let v = self else { return "—" }
        return v >= 10_000 ? (v / 1000).formatted(.number.precision(.fractionLength(2))) + " s"
                           : v.formatted(.number.precision(.fractionLength(1))) + " ms"
    }
}

extension OrderTiming {
    /// Average fill above the ask at submit (per contract); positive = paid more.
    var slippage: Double? {
        guard let fill = averageFill, let ask = askAtSubmit else { return nil }
        return fill - ask
    }
}

/// Count, median, p90, min and max of the submit → filled times.
struct LatencyStats {
    let count: Int
    let median: Double?
    let p90: Double?
    let min: Double?
    let max: Double?

    init(_ log: [OrderTiming]) {
        let filled = log.compactMap(\.filledMs).sorted()
        count = filled.count
        func pct(_ p: Double) -> Double? {
            guard !filled.isEmpty else { return nil }
            // Nearest-rank percentile.
            let rank = Int((p * Double(filled.count)).rounded(.up)) - 1
            return filled[Swift.max(0, Swift.min(filled.count - 1, rank))]
        }
        median = pct(0.5)
        p90 = pct(0.9)
        min = filled.first
        max = filled.last
    }
}

/// One line above the strategy list: last fill time and the distribution.
struct LatencySummaryBar: View {
    @Environment(AppStore.self) private var store
    @State private var showingHistory = false

    var body: some View {
        let stats = LatencyStats(store.latencyLog)
        HStack(spacing: 12) {
            Label("Entry fill time", systemImage: "stopwatch").font(.caption.bold())
            if stats.count == 0 {
                Text("No market entries timed yet").font(.caption).foregroundStyle(.secondary)
            } else {
                Group {
                    Text("last \(store.latencyLog.last(where: { $0.filledMs != nil })?.filledMs.ms ?? "—")")
                    Text("median \(stats.median.ms)")
                    Text("p90 \(stats.p90.ms)")
                    Text("n=\(stats.count)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Spacer()
            Button("History…") { showingHistory = true }
                .controlSize(.small)
                .disabled(store.latencyLog.isEmpty)
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $showingHistory) { LatencyHistoryView() }
    }
}

struct LatencyHistoryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var rows: [OrderTiming] { store.latencyLog.reversed() }

    var body: some View {
        let stats = LatencyStats(store.latencyLog)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Entry Fill Latency").font(.title2.bold())
                Spacer()
                Text("n=\(stats.count) · median \(stats.median.ms) · p90 \(stats.p90.ms) · min \(stats.min.ms) · max \(stats.max.ms)")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Timed in the app with a microsecond clock as each IB event arrived; IB's own timestamps are whole seconds. Each column is measured from the submit.")
                .font(.caption).foregroundStyle(.secondary)

            Table(rows) {
                Group {
                TableColumn("Submitted") { (t: OrderTiming) in
                    Text(Date(timeIntervalSince1970: Double(t.submittedAtMs) / 1000)
                        .formatted(.dateTime.month(.abbreviated).day().hour().minute().second().secondFraction(.fractional(3))))
                }
                .width(min: 130, ideal: 150)
                TableColumn("Contract") { (t: OrderTiming) in Text(t.localSymbol).monospaced() }.width(min: 120, ideal: 170)
                TableColumn("Qty") { (t: OrderTiming) in Text(t.quantity.quantity) }.width(35)
                TableColumn("Trigger→Submit") { (t: OrderTiming) in Text(t.triggerToSubmitMs.ms) }.width(90)
                TableColumn("Sent") { (t: OrderTiming) in Text(t.sentMs.ms) }.width(65)
                TableColumn("Ack") { (t: OrderTiming) in Text(t.ackMs.ms).help(t.ackStatus) }.width(70)
                TableColumn("1st Fill") { (t: OrderTiming) in Text(t.firstFillMs.ms) }.width(70)
                TableColumn("Filled") { (t: OrderTiming) in Text(t.filledMs.ms).fontWeight(.semibold) }.width(75)
                }
                TableColumn("Avg / Ask") { (t: OrderTiming) in
                    Text("\(t.averageFill.formatted(digits: 2)) / \(t.askAtSubmit.formatted(digits: 2))")
                }
                .width(85)
                TableColumn("Slip") { (t: OrderTiming) in
                    Text(t.slippage.map { $0.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())) } ?? "—")
                        .foregroundStyle(t.slippage.map { $0 > 0 ? Color.red : $0 < 0 ? Color.green : Color.primary } ?? .secondary)
                }
                .width(50)
                TableColumn("Outcome") { (t: OrderTiming) in Text(t.outcome).foregroundStyle(t.outcome == "Filled" ? .primary : Color.orange) }.width(70)
            }
            .monospacedDigit()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 420)
    }
}

nonisolated extension OrderTiming: @retroactive Identifiable {
    public var id: String { "\(orderId)-\(submittedAtMs)" }
}
