//
//  AccountView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct AccountView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.summary
        let currency = s?.currency ?? "USD"
        Form {
            Section("Balances") {
                LabeledContent("Net Liquidation", value: s?.netLiquidation.money(currency) ?? "—")
                LabeledContent("Total Cash", value: s?.totalCash.money(currency) ?? "—")
                LabeledContent("Buying Power", value: s?.buyingPower.money(currency) ?? "—")
                LabeledContent("Available Funds", value: s?.availableFunds.money(currency) ?? "—")
                LabeledContent("Gross Position Value", value: s?.grossPositionValue.money(currency) ?? "—")
            }
            Section("P&L") {
                pnlRow("Daily", s?.dailyPnl, currency)
                pnlRow("Unrealized", s?.unrealizedPnl, currency)
                pnlRow("Realized", s?.realizedPnl, currency)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .navigationTitle("Account \(store.account)")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshSummary() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func pnlRow(_ label: String, _ value: Double?, _ currency: String) -> some View {
        LabeledContent(label) {
            Text(value.money(currency))
                .foregroundStyle((value ?? 0) < 0 ? .red : (value ?? 0) > 0 ? .green : .primary)
        }
    }
}
