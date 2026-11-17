//
//  PnLTallyView.swift
//  IBKR Swift
//
//  Realized P&L after commissions for Day / Week / Month / Year, from the Rust ledger
//  (`ledger.rs`). IB's API only reaches 7 days back, so longer periods cover what the
//  app has recorded; an incomplete period says so.
//

import IbkrCore
import SwiftUI

extension PnlPeriod {
    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

struct PnLTallyView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("orders.pnlPeriod") private var periodRaw = "day"

    private var period: PnlPeriod {
        [PnlPeriod.day, .week, .month, .year].first { $0.title.lowercased() == periodRaw } ?? .day
    }

    private var tally: PnlTally? { store.ledger?.tallies.first { $0.period == period } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                summary
                periodPicker
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 12) {
                summary
                periodPicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monospacedDigit()
        .padding(16)
        .background(AppTheme.accent.opacity(0.04))
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Realized P/L · net of fees").font(.caption).foregroundStyle(.secondary)
                if let tally {
                    Text(Optional(tally.netRealized).money("USD"))
                        .font(.title2.bold())
                        .foregroundStyle(tally.netRealized > 0 ? .green : tally.netRealized < 0 ? .red : .primary)
                        .contentTransition(.numericText())
                } else {
                    Text("—").font(.title2.bold()).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 130, alignment: .leading)

            if let tally {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Commissions & fees \(Optional(tally.commissions).money("USD"))")
                    Text(tradesLine(tally)).foregroundStyle(.secondary)
                    if let note = note(tally) {
                        Text(note).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .help("IB's realized P&L on closing fills, which already subtracts the commissions on both the opening and closing legs. Commissions & fees counts every fill in the period, including positions still open.")
            }

        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $periodRaw) {
            ForEach([PnlPeriod.day, .week, .month, .year], id: \.self) { p in
                Text(p.title).tag(p.title.lowercased())
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func tradesLine(_ t: PnlTally) -> String {
        guard t.fills > 0 else { return "No fills \(sinceText(t.fromDay))" }
        var s = "\(t.closingFills) closing \(t.closingFills == 1 ? "fill" : "fills")"
        if t.closingFills > 0 { s += " · \(t.winners)W / \(t.losers)L" }
        s += " · \(t.fills) total"
        return s
    }

    private func note(_ t: PnlTally) -> String? {
        var notes: [String] = []
        if !t.complete {
            if let since = store.ledger?.recordedSince {
                notes.append("Recorded since \(label(since)); IB's API only keeps 7 days")
            } else {
                notes.append("Reading fills from IB…")
            }
        }
        if t.awaitingCommission > 0 { notes.append("\(t.awaitingCommission) awaiting commission") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func sinceText(_ day: String) -> String {
        period == .day ? "today" : "since \(label(day))"
    }

    /// "YYYYMMDD" → "Nov 12".
    private func label(_ ymd: String) -> String {
        guard let date = Eastern.ymd.date(from: ymd) else { return ymd }
        return date.formatted(Date.FormatStyle(timeZone: Eastern.timeZone).month(.abbreviated).day())
    }
}
