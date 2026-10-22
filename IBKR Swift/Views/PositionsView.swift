//
//  PositionsView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct PositionsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Table(store.positions) {
            TableColumn("Symbol") { p in
                // Options etc. share a symbol; show IB's full local symbol for them.
                Text(p.secType == "STK" || p.localSymbol.isEmpty ? p.symbol : p.localSymbol)
                    .monospaced()
            }
            TableColumn("Type", value: \.secType).width(50)
            TableColumn("Quantity") { p in Text(p.quantity.quantity) }
            TableColumn("Avg Cost") { p in Text(Optional(p.averageCost).formatted(digits: 4)) }
            TableColumn("Currency", value: \.currency).width(60)
        }
        .monospacedDigit()
        .overlay {
            if store.positions.isEmpty {
                ContentUnavailableView("No Positions", systemImage: "tray")
            }
        }
        .navigationTitle("Positions")
    }
}
