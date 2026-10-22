//
//  QuoteView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct QuoteView: View {
    @Environment(AppStore.self) private var store
    @State private var symbol = "AAPL"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                TextField("Symbol", text: $symbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { store.watchQuote(symbol: symbol) }
                Button("Watch") { store.watchQuote(symbol: symbol) }
                    .keyboardShortcut(.defaultAction)
            }

            if let q = store.quote {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(q.symbol).font(.largeTitle.bold())
                    Text(q.last.formatted()).font(.largeTitle).monospacedDigit()
                    change(q)
                    if q.delayed {
                        Text("DELAYED").font(.caption.bold()).foregroundStyle(.orange)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 8) {
                    GridRow {
                        cell("Bid", q.bid.formatted(), q.bidSize)
                        cell("Ask", q.ask.formatted(), q.askSize)
                    }
                    GridRow {
                        cell("Close", q.close.formatted(), nil)
                        cell("Volume", q.volume.map(\.quantity) ?? "—", nil)
                    }
                }
                .monospacedDigit()
            }
            Spacer()
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
                Text(value).font(.title2)
                if let size { Text("× \(size.quantity)").foregroundStyle(.secondary) }
            }
        }
    }
}
