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
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                HStack {
                    SectionHeading(title: "Portfolio overview", icon: "chart.pie", tint: .indigo)
                    Spacer()
                    ModeBadge(isLive: store.isLive)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Net Liquidation").font(.callout).foregroundStyle(.secondary)
                        Text(s?.netLiquidation.money(currency) ?? "—")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Label("Today’s P&L", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(s?.dailyPnl.money(currency) ?? "—")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(pnlColor(s?.dailyPnl))
                    }
                }
                .monospacedDigit()
                .card(padding: 24, tint: .indigo)

                section("Balances", icon: "wallet.bifold", columns: 4) {
                    StatCard(title: "Total Cash", value: s?.totalCash.money(currency) ?? "—", icon: "banknote", accent: .teal)
                    StatCard(title: "Buying Power", value: s?.buyingPower.money(currency) ?? "—", icon: "bolt", accent: .indigo)
                    StatCard(title: "Available Funds", value: s?.availableFunds.money(currency) ?? "—", icon: "creditcard", accent: .blue)
                    StatCard(title: "Gross Position Value", value: s?.grossPositionValue.money(currency) ?? "—", icon: "chart.pie", accent: .purple)
                }
                section("Profit & loss", icon: "chart.line.uptrend.xyaxis", columns: 2) {
                    StatCard(title: "Unrealized", value: s?.unrealizedPnl.money(currency) ?? "—", tint: pnlColor(s?.unrealizedPnl), icon: "waveform.path", accent: .teal)
                    StatCard(title: "Realized", value: s?.realizedPnl.money(currency) ?? "—", tint: pnlColor(s?.realizedPnl), icon: "checkmark.circle", accent: .blue)
                }
                RiskSection()
            }
            .padding(AppTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Account \(store.account)")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshSummary() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private func section(_ title: String, icon: String, columns: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: title, icon: icon)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12, content: content)
        }
    }
}
