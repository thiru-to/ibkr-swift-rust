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
            Text(u.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)

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
                        Text("TP \(u.takeProfitPrice.formatted()) · Stop \(u.stopPrice.formatted())\(u.stopLimitPrice.map { " / lmt \($0.formatted())" } ?? "")")
                        Text(u.eodCloseAt.map { "EOD \($0.split(separator: " ").dropFirst().first ?? "")" } ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                if let pnl = u.realizedPnl {
                    GridRow {
                        Text("P&L").foregroundStyle(.secondary)
                        Text(pnl.formatted(.currency(code: "USD")))
                            .foregroundStyle(pnl >= 0 ? .green : .red)
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
                    Button("Close Now…") { confirmClose = true }
                case .closing:
                    EmptyView()
                case .closed, .disarmed, .failed:
                    Button("Dismiss") { store.dismissStrategy(u.id) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .confirmationDialog("Close position now?", isPresented: $confirmClose) {
            Button(store.isLive ? "Sell LIVE at Market" : "Sell at Market", role: .destructive) { store.closeNow(u.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sells \(u.filledQuantity.quantity) \(u.optionLocalSymbol) at market. Working exits are cancelled by IB (same OCA group).")
        }
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
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}
