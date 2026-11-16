//
//  StrategiesView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct StrategiesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            LatencySummaryBar()
            Divider()
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
}

private struct StrategyRow: View {
    @Environment(AppStore.self) private var store
    let update: StrategyUpdate
    let spec: StrategySpec?

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
                if let timing = u.entryTiming {
                    GridRow {
                        Text("Fill time").foregroundStyle(.secondary)
                        Text(timing.filledMs.ms + (timing.filledMs == nil && timing.outcome == "Working" ? " (working…)" : ""))
                            .fontWeight(.semibold)
                        Text("ack \(timing.ackMs.ms) · 1st fill \(timing.firstFillMs.ms)\(slip(timing))")
                            .foregroundStyle(.secondary)
                            .help("Measured from the submit, as each IB event reached the app. Sent to Gateway in \(timing.sentMs.ms)\(timing.triggerToSubmitMs.map { "; trigger → submit \(Optional($0).ms)" } ?? "").")
                    }
                }
                if let p = store.positionPnl[u.contractId], u.state != .closed, p.position != 0 {
                    GridRow {
                        Text("Unrealized").foregroundStyle(.secondary)
                        if let pnl = p.unrealizedPnl {
                            Text(pnl.formatted(.currency(code: "USD")) + percent(pnl, value: p.value))
                                .fontWeight(.semibold)
                                .foregroundStyle(pnlColor(pnl))
                                .contentTransition(.numericText())
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                        Text(positionNote(p, u))
                            .foregroundStyle(.secondary)
                            .help("IB's mark-to-market against your average cost, which includes the entry commission. It covers the account's whole position in this contract.")
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
                        // Immediate market sell, no confirmation (an exit only, inside the OCA group;
                        // the strategy ignores repeat presses once it's closing).
                        Button(store.isLive ? "Close Now (LIVE)" : "Close Now") { store.closeNow(u.id) }
                            .tint(.red)
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
    }
}

extension StrategyRow {
    fileprivate func slip(_ t: OrderTiming) -> String {
        guard let s = t.slippage else { return "" }
        return " · slip \(s.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always())))"
    }

    /// " (+12.5%)" of the cost basis (market value − unrealized).
    fileprivate func percent(_ pnl: Double, value: Double?) -> String {
        guard let value else { return "" }
        let cost = value - pnl
        guard abs(cost) > 0.005 else { return "" }
        return " (" + (pnl / abs(cost)).formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())) + ")"
    }

    /// Market value, plus the account's size when it differs from this strategy's fill.
    fileprivate func positionNote(_ p: PositionPnl, _ u: StrategyUpdate) -> String {
        var note = p.value.map { "value \($0.formatted(.currency(code: "USD")))" } ?? ""
        if p.position != u.filledQuantity {
            note += (note.isEmpty ? "" : " · ") + "account holds \(p.position.quantity)"
        }
        return note
    }

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
