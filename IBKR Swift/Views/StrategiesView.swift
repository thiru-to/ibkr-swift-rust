//
//  StrategiesView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct StrategiesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            ForEach(store.strategies, id: \.id) { u in
                StrategyRow(update: u, spec: store.strategySpecs[u.id])
            }
        }
        .overlay {
            if store.strategies.isEmpty {
                ContentUnavailableView("No Strategies", systemImage: "scope",
                                       description: Text("Armed and recent strategies appear here."))
            }
        }
    }
}

private struct StrategyRow: View {
    @Environment(AppStore.self) private var store
    let update: StrategyUpdate
    let spec: StrategySpec?
    @State private var confirmClose = false

    var body: some View {
        let u = update
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(u.optionLocalSymbol).font(.headline).monospaced()
                Text("×\(Int(spec?.quantity ?? u.filledQuantity))").foregroundStyle(.secondary)
                Spacer()
                StateChip(state: u.state)
            }
            Text(u.message)
                .font(.callout)
                .foregroundStyle(u.state == .unprotected || u.state == .failed ? .red : .secondary)
                .textSelection(.enabled)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                if let t = spec?.trigger {
                    GridRow {
                        Text("Trigger").foregroundStyle(.secondary)
                        Text("\(t.underlying) \(t.direction == .risesTo ? "≥" : "≤") \(t.price.formatted())")
                        Text("last \(u.underlyingLast.formatted())\(u.underlyingDelayed ? " (delayed)" : "")")
                            .foregroundStyle(.secondary)
                    }
                }
                if u.averageFill != nil {
                    GridRow {
                        Text("Fill").foregroundStyle(.secondary)
                        Text("\(u.filledQuantity.quantity) @ \(u.averageFill.formatted())")
                        Text("")
                    }
                    GridRow {
                        Text("Exits").foregroundStyle(.secondary)
                        Text(exits(u))
                        Text(u.eodCloseAt.map { "EOD \($0.split(separator: " ").dropFirst().first ?? "")" } ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                if let pnl = u.realizedPnl {
                    GridRow {
                        Text("P&L").foregroundStyle(.secondary)
                        Text(pnl.formatted(.currency(code: "USD")))
                            .foregroundStyle(pnlColor(pnl))
                        Text("exit \(u.exitPrice.formatted())").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .monospacedDigit()

            HStack {
                Spacer()
                switch u.state {
                case .arming, .armed, .waitingDelayedData:
                    Button("Disarm") { store.disarm(u.id) }
                case .entering:
                    Button("Cancel Entry") { store.disarm(u.id) }
                case .protected, .open, .unprotected:
                    if u.canClose {
                        Button("Close Now…") { confirmClose = true }
                    } else {
                        // The task has stopped tracking this position; the app can't act on it.
                        Text("Manage this position in TWS").font(.caption).foregroundStyle(.red)
                        Button("Dismiss") { store.dismissStrategy(u.id) }
                    }
                case .closing:
                    EmptyView()
                case .closed, .disarmed, .failed:
                    Button("Dismiss") { store.dismissStrategy(u.id) }
                }
            }
            .controlSize(.small)
        }
        .card(padding: 12)
        .listRowSeparator(.hidden)
        .confirmationDialog("Close position now?", isPresented: $confirmClose) {
            Button(store.isLive ? "Sell LIVE at Market" : "Sell at Market", role: .destructive) { store.closeNow(u.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sells the remaining \(u.optionLocalSymbol) position at market. Working exits are cancelled by IB (same OCA group).")
        }
    }
}

extension StrategyRow {
    /// Live prices of the working exits (they can be edited from the position details),
    /// falling back to the planned ones.
    fileprivate func exits(_ u: StrategyUpdate) -> String {
        let working = store.orders.filter {
            u.exitOrderIds.contains($0.orderId) && $0.clientId == store.sessionClientId && $0.group == .open
        }
        let tp = working.first { $0.orderType == "LMT" }?.limitPrice ?? u.takeProfitPrice
        let stopOrder = working.first { $0.orderType.hasPrefix("STP") }
        let stop = stopOrder?.stopPrice ?? u.stopPrice
        let limit = stopOrder.map { $0.limitPrice } ?? u.stopLimitPrice
        return "TP \(tp.formatted()) · Stop \(stop.formatted())\(limit.map { " / lmt \($0.formatted())" } ?? "")"
    }
}

private struct StateChip: View {
    let state: StrategyState

    var body: some View {
        let (label, color): (String, Color) = switch state {
        case .arming: ("ARMING", .gray)
        case .armed: ("ARMED", .blue)
        case .waitingDelayedData: ("WAITING · DELAYED", .orange)
        case .entering: ("ENTERING", .purple)
        case .protected: ("PROTECTED", .green)
        case .open: ("OPEN · NO EXITS", .orange)
        case .closing: ("CLOSING", .purple)
        case .closed: ("CLOSED", .gray)
        case .disarmed: ("DISARMED", .gray)
        case .failed: ("FAILED", .red)
        case .unprotected: ("UNPROTECTED", .red)
        }
        Pill(text: label, color: color, solid: state == .unprotected)
    }
}
