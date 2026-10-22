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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Net Liquidation").font(.callout).foregroundStyle(.secondary)
                        Text(s?.netLiquidation.money(currency) ?? "—")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Today").font(.callout).foregroundStyle(.secondary)
                        Text(s?.dailyPnl.money(currency) ?? "—")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(pnlColor(s?.dailyPnl))
                    }
                }
                .monospacedDigit()
                .card(padding: 18)

                section("Balances") {
                    StatCard(title: "Total Cash", value: s?.totalCash.money(currency) ?? "—")
                    StatCard(title: "Buying Power", value: s?.buyingPower.money(currency) ?? "—")
                    StatCard(title: "Available Funds", value: s?.availableFunds.money(currency) ?? "—")
                    StatCard(title: "Gross Position Value", value: s?.grossPositionValue.money(currency) ?? "—")
                }
                section("P&L") {
                    StatCard(title: "Unrealized", value: s?.unrealizedPnl.money(currency) ?? "—", tint: pnlColor(s?.unrealizedPnl))
                    StatCard(title: "Realized", value: s?.realizedPnl.money(currency) ?? "—", tint: pnlColor(s?.realizedPnl))
                }
            }
            .padding(20)
        }
        .navigationTitle("Account \(store.account)")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshSummary() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12, content: content)
        }
    }
}
