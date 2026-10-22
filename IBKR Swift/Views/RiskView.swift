//
//  RiskView.swift
//  IBKR Swift
//
//  Risk limits and the kill switch. The Rust side (risk.rs) enforces everything: only
//  opening orders are checked, tightening applies now and loosening from the next trading
//  day, and a halt lasts until the US/Eastern day rolls over. Exits are never blocked.
//

import IbkrCore
import SwiftUI

/// The Account screen's Risk card: status, limits and the Halt Trading button.
struct RiskSection: View {
    @Environment(AppStore.self) private var store
    @State private var maxDailyLoss: Double?
    @State private var maxCost: Double?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Risk").font(.headline)
            if let risk = store.risk {
                content(risk)
                    .card()
                    .onAppear { load(risk) }
            } else {
                Text("Starting…").foregroundStyle(.secondary).card()
            }
        }
    }

    private func content(_ risk: RiskStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let reason = risk.halted {
                    Pill(text: "HALTED", color: .red, solid: true)
                    Text(reason).foregroundStyle(.red)
                } else {
                    Pill(text: "TRADING ALLOWED", color: .green)
                }
                Spacer()
                HaltButton()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Today's P&L (IB)").foregroundStyle(.secondary)
                    Text(risk.dailyPnl.money("USD")).foregroundStyle(pnlColor(risk.dailyPnl))
                    Text(risk.running ? "" : "not tracking").foregroundStyle(.orange)
                }
                GridRow {
                    Text("Max daily loss").foregroundStyle(.secondary)
                    TextField("Off", value: $maxDailyLoss, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 110)
                    Text(current(risk.limits.maxDailyLoss)).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Max cost per trade").foregroundStyle(.secondary)
                    TextField("Off", value: $maxCost, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 110)
                    Text(current(risk.limits.maxCostPerTrade)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()

            if let pending = risk.pending {
                Label("From the next trading day: max daily loss \(describe(pending.maxDailyLoss)), max cost per trade \(describe(pending.maxCostPerTrade)).",
                      systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Text("Empty = off. Tighter limits apply now; looser ones from the next trading day (US/Eastern).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { apply() }
                    .disabled(wanted == (risk.pending ?? risk.limits))
            }
        }
    }

    private var wanted: RiskLimits {
        RiskLimits(maxDailyLoss: maxDailyLoss, maxCostPerTrade: maxCost)
    }

    /// Shows what's pending if anything is, since that's what the user last asked for.
    private func load(_ risk: RiskStatus) {
        let limits = risk.pending ?? risk.limits
        maxDailyLoss = limits.maxDailyLoss
        maxCost = limits.maxCostPerTrade
    }

    private func apply() {
        do {
            try store.setRiskLimits(wanted)
            problem = nil
        } catch {
            problem = error.message
        }
    }

    private func current(_ value: Double?) -> String {
        "now \(describe(value))"
    }

    private func describe(_ value: Double?) -> String {
        value.map { Optional($0).money("USD") } ?? "off"
    }
}

/// Kill switch: halts opening orders for the rest of the trading day, after a confirmation.
struct HaltButton: View {
    @Environment(AppStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Button("Halt Trading", systemImage: "hand.raised.fill") { confirming = true }
            .tint(.red)
            .disabled(store.risk == nil || store.risk?.halted != nil)
            .help("Stop all new entries for the rest of the trading day")
            .confirmationDialog("Halt trading for the rest of today?", isPresented: $confirming) {
                Button("Halt Trading", role: .destructive) { store.haltTrading() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New entries are blocked until the next trading day (US/Eastern), even after a restart. Armed strategies are disarmed and working entry orders are cancelled. Exit orders (take-profit, stop, EOD) stay at IB.")
            }
    }
}
