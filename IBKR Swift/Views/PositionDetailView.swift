//
//  PositionDetailView.swift
//  IBKR Swift
//
//  One position: live value and P&L, its working orders (editable when this connection
//  placed them), and Close / Add Stop & Take-Profit. Each action opens a review panel
//  that shows LIVE/PAPER before anything is sent; keep it that way. The Rust side
//  (position.rs) re-checks everything against IB before sending.
//

import IbkrCore
import SwiftUI

struct PositionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let positionId: Position.ID

    private enum Panel { case none, close, protect }
    @State private var panel = Panel.none
    /// Shown after the position goes flat, so the sheet doesn't go blank.
    @State private var lastKnown: Position?

    private var position: Position? { store.positions.first { $0.id == positionId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = position ?? lastKnown {
                header(p)
                if position == nil {
                    Label("This position is now flat.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .card(padding: 10)
                }
                PositionStats(position: p, quote: store.positionQuote)

                if let s = store.strategy(managing: p) {
                    HStack {
                        Label("Managed by a strategy", systemImage: "scope")
                        Spacer()
                        Pill(text: "\(s.state)".uppercased(), color: .purple)
                    }
                    .font(.callout)
                    .card(padding: 10)
                }

                WorkingOrdersSection(orders: store.workingOrders(for: p), quote: store.positionQuote)

                if position != nil {
                    switch panel {
                    case .none:
                        HStack {
                            Button("Add Stop / Take-Profit…") { panel = .protect }
                            Spacer()
                            Button("Close Position…") { panel = .close }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                    case .close:
                        ClosePanel(position: p) { panel = .none }
                    case .protect:
                        ProtectPanel(position: p) { panel = .none }
                    }
                }
            } else {
                ContentUnavailableView("Position not found", systemImage: "tray")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .monospacedDigit()
        .onAppear {
            lastKnown = position
            if let position { store.watchPosition(contractId: position.contractId) }
        }
        .onDisappear { store.watchPosition(contractId: nil) }
        .onChange(of: position) { if let position { lastKnown = position } }
    }

    private func header(_ p: Position) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(p.displaySymbol).font(.system(size: 24, weight: .bold, design: .rounded))
            Pill(text: p.secType, color: p.secType == "OPT" ? .purple : .blue)
            Spacer()
            ModeBadge(isLive: store.isLive)
        }
    }
}

/// Mark price: mid when there's a two-sided market, else last.
private func mark(_ q: Quote?) -> Double? {
    if let bid = q?.bid, let ask = q?.ask, bid > 0, ask > 0 { return (bid + ask) / 2 }
    return q?.last
}

private struct PositionStats: View {
    let position: Position
    let quote: Quote?

    var body: some View {
        let p = position
        let m = mark(quote)
        let value = m.map { $0 * p.quantity * p.multiplier }
        let pnl = m.map { ($0 - p.averagePrice) * p.quantity * p.multiplier }
        let pnlPct = m.flatMap { m in p.averagePrice > 0 ? (m - p.averagePrice) / p.averagePrice * (p.quantity < 0 ? -1 : 1) : nil }

        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                StatCard(title: "Quantity", value: p.quantity.quantity, tint: p.quantity < 0 ? .red : .primary)
                StatCard(title: "Avg Price", value: Optional(p.averagePrice).formatted(digits: 2))
                StatCard(title: "Mark", value: m.formatted(digits: 2))
                StatCard(title: "Market Value", value: value.money(p.currency))
                StatCard(title: "Unrealized P&L",
                         value: pnl.money(p.currency) + (pnlPct.map { " (\($0.formatted(.percent.precision(.fractionLength(1)))))" } ?? ""),
                         tint: pnlColor(pnl))
            }
            if let quote {
                HStack(spacing: 6) {
                    Text("Bid").foregroundStyle(.secondary)
                    Text(quote.bid.formatted()).foregroundStyle(.red)
                    Text("Ask").foregroundStyle(.secondary)
                    Text(quote.ask.formatted()).foregroundStyle(.green)
                    Text("Last \(quote.last.formatted())").foregroundStyle(.secondary)
                    if quote.delayed { Pill(text: "DELAYED", color: .orange) }
                }
                .font(.callout)
            } else {
                Text("Waiting for a quote…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Working orders

private struct WorkingOrdersSection: View {
    let orders: [OrderInfo]
    let quote: Quote?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Working orders").font(.headline)
            if orders.isEmpty {
                Text("None. This position has no stop or take-profit at IB.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(orders) { WorkingOrderRow(order: $0, quote: quote) }
            }
        }
    }
}

/// A working order with an inline price editor (own orders with a limit or stop price).
private struct WorkingOrderRow: View {
    @Environment(AppStore.self) private var store
    let order: OrderInfo
    let quote: Quote?

    @State private var editing = false
    @State private var limit: Double?
    @State private var stop: Double?
    @State private var busy = false
    @State private var outcome: Result<String, ActionError>?

    private var editable: Bool {
        order.clientId == store.sessionClientId && order.orderId > 0 && (order.limitPrice != nil || order.stopPrice != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(String(order.orderId))").foregroundStyle(.secondary)
                Text(order.action.uppercased()).fontWeight(.semibold).foregroundStyle(order.isBuy ? .green : .red)
                Text("\(order.quantity.quantity) \(order.orderType)")
                Text(prices).fontWeight(.medium)
                Spacer()
                StatusPill(order: order)
                if editable && !editing {
                    Button("Edit") { startEditing() }.controlSize(.small)
                } else if !editable && order.clientId != store.sessionClientId {
                    Text("client \(String(order.clientId))").font(.caption).foregroundStyle(.secondary)
                        .help("Placed by TWS or another API client; change it there.")
                }
            }
            if editing { editor }
            switch outcome {
            case .success(let text): Text(text).font(.callout).foregroundStyle(.green)
            case .failure(let error): Text(error.message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case nil: EmptyView()
            }
        }
        .card(padding: 10)
    }

    private var prices: String {
        [order.stopPrice.map { "stp \(Optional($0).formatted())" }, order.limitPrice.map { "lmt \(Optional($0).formatted())" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    @ViewBuilder
    private var editor: some View {
        HStack {
            if order.stopPrice != nil {
                TextField("Stop", value: $stop, format: .number.precision(.fractionLength(0...4))).frame(width: 90)
            }
            if order.limitPrice != nil {
                TextField("Limit", value: $limit, format: .number.precision(.fractionLength(0...4))).frame(width: 90)
            }
            Spacer()
            Button("Cancel") { editing = false }.disabled(busy)
            Button(store.isLive ? "Save LIVE Change" : "Save Change") { save() }
                .buttonStyle(.borderedProminent)
                .tint(store.isLive ? .red : .accentColor)
                .disabled(busy || !changed)
            if busy { ProgressView().controlSize(.small) }
        }
        if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
    }

    private var changed: Bool {
        (order.limitPrice != nil && limit != order.limitPrice) || (order.stopPrice != nil && stop != order.stopPrice)
    }

    /// A new price on the wrong side of the market executes at once.
    private var warning: String? {
        let sell = !order.isBuy
        if let stop, order.stopPrice != nil {
            if sell, let bid = quote?.bid, stop >= bid { return "A sell stop at or above the bid (\(bid.formatted())) triggers immediately." }
            if !sell, let ask = quote?.ask, stop <= ask { return "A buy stop at or below the ask (\(ask.formatted())) triggers immediately." }
        }
        if let limit, order.stopPrice == nil {
            if sell, let bid = quote?.bid, limit <= bid { return "A sell limit at or below the bid (\(bid.formatted())) fills immediately." }
            if !sell, let ask = quote?.ask, limit >= ask { return "A buy limit at or above the ask (\(ask.formatted())) fills immediately." }
        }
        return nil
    }

    private func startEditing() {
        limit = order.limitPrice
        stop = order.stopPrice
        outcome = nil
        editing = true
    }

    private func save() {
        busy = true
        Task {
            do throws(ActionError) {
                let text = try await store.modifyOrder(order,
                                                       limitPrice: limit != order.limitPrice ? limit : nil,
                                                       stopPrice: stop != order.stopPrice ? stop : nil)
                outcome = .success(text)
                editing = false
            } catch {
                outcome = .failure(error)
            }
            busy = false
        }
    }
}

// MARK: - Close

/// Review for closing the whole position with a capped limit (see the wide-spread note:
/// it fills like a market order normally, but won't chase a blown-out quote).
private struct ClosePanel: View {
    @Environment(AppStore.self) private var store
    let position: Position
    let done: () -> Void

    @State private var capPercent: Double?
    @State private var busy = false
    @State private var outcome: Result<String, ActionError>?
    @State private var confirmStrategyClose = false

    private var quote: Quote? { store.positionQuote }
    private var long: Bool { position.quantity > 0 }

    /// The price closing trades against: the bid when selling, the ask when buying.
    private var reference: Double? { (long ? quote?.bid : quote?.ask) ?? quote?.last }

    private var limitPrice: Double? {
        guard let reference, reference > 0, let cap = capPercent, cap >= 0 else { return nil }
        return long ? reference * (1 - cap / 100) : reference * (1 + cap / 100)
    }

    var body: some View {
        let working = store.workingOrders(for: position)
        let foreign = working.filter { $0.clientId != store.sessionClientId }
        VStack(alignment: .leading, spacing: 10) {
            Text("Close position").font(.headline)
            if let s = store.strategy(managing: position) {
                strategyClose(s)
            } else if !foreign.isEmpty {
                Label("Order(s) \(foreign.map { "#\($0.orderId)" }.joined(separator: ", ")) on this contract belong to TWS or another API client. Cancel them there first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                buttons(canSubmit: false)
            } else {
                Text("\(long ? "SELL" : "BUY") \(abs(position.quantity).quantity) \(position.displaySymbol)")
                    .font(.title3.bold())
                    .foregroundStyle(long ? .red : .green)
                HStack {
                    Text("Max slippage")
                    TextField("%", value: $capPercent, format: .number.precision(.fractionLength(0...2))).frame(width: 60)
                    Text("% \(long ? "below the bid" : "above the ask")").foregroundStyle(.secondary)
                }
                if let limitPrice, let reference {
                    Text("Limit ≈ \(Optional(limitPrice).formatted(digits: 2)) (\(long ? "bid" : "ask") \(reference.formatted())), rounded to a valid tick. Day order.")
                        .font(.callout)
                    Text("Est. \(long ? "proceeds" : "cost") at worst \(Optional(limitPrice * abs(position.quantity) * position.multiplier).money(position.currency))")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Waiting for a quote to price the close…").font(.callout).foregroundStyle(.secondary)
                }
                if !working.isEmpty {
                    Label("Cancels first, waiting for IB to confirm: \(working.map { "#\($0.orderId) \($0.orderType)" }.joined(separator: ", ")). If the close then fails, the position has no exits.",
                          systemImage: "info.circle")
                        .font(.callout)
                }
                if quote?.delayed == true {
                    Label("The quote is delayed; the limit may be off the real market.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("Account \(store.account) — \(store.isLive ? "LIVE (real money)" : "PAPER")").font(.callout)
                result
                buttons(canSubmit: limitPrice != nil)
            }
        }
        .card(padding: 12)
        .onAppear { capPercent = position.secType == "OPT" ? 5 : 0.5 }
    }

    /// Strategy-managed: close through its own OCA group (a market order).
    @ViewBuilder
    private func strategyClose(_ s: StrategyUpdate) -> some View {
        if s.canClose {
            Text("A running strategy manages this position. Closing it here sends the strategy's Close Now: a market sell inside its OCA group, so its exits can't also fill.")
                .font(.callout)
            HStack {
                Spacer()
                Button("Back", action: done)
                Button(store.isLive ? "Close via Strategy (LIVE)…" : "Close via Strategy…") { confirmStrategyClose = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .confirmationDialog("Sell at market now?", isPresented: $confirmStrategyClose) {
                Button(store.isLive ? "Sell LIVE at Market" : "Sell at Market", role: .destructive) {
                    store.closeNow(s.id)
                    outcome = .success("Close Now sent; follow it on the Options screen.")
                }
                Button("Cancel", role: .cancel) {}
            }
            result
        } else {
            Text("The strategy managing this position is \("\(s.state)".lowercased()) and can't close it right now. Wait for it to finish, or manage the position in TWS.")
                .font(.callout).foregroundStyle(.orange)
            HStack { Spacer(); Button("Back", action: done) }
        }
    }

    @ViewBuilder
    private var result: some View {
        switch outcome {
        case .success(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let error): Label(error.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
        case nil: EmptyView()
        }
    }

    private func buttons(canSubmit: Bool) -> some View {
        HStack {
            if busy { ProgressView().controlSize(.small); Text("Working with IB…").foregroundStyle(.secondary) }
            Spacer()
            Button("Back", action: done).disabled(busy)
            // No Return shortcut: sending takes a click.
            Button(store.isLive ? "Close LIVE Position" : "Close Paper Position") { submit() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canSubmit || busy || isDone)
        }
    }

    private var isDone: Bool {
        if case .success = outcome { return true }
        return false
    }

    private func submit() {
        guard let limitPrice else { return }
        busy = true
        outcome = nil
        Task {
            do throws(ActionError) {
                outcome = .success(try await store.closePosition(position, limitPrice: limitPrice))
            } catch {
                outcome = .failure(error)
            }
            busy = false
        }
    }
}

// MARK: - Stop / take-profit

/// Attach a take-profit and/or stop: one OCA group, GTC, sized from IB's quantity.
private struct ProtectPanel: View {
    @Environment(AppStore.self) private var store
    let position: Position
    let done: () -> Void

    @State private var takeProfit: Double?
    @State private var stop: Double?
    @State private var useStopLimit = false
    @State private var stopLimit: Double?
    @State private var busy = false
    @State private var outcome: Result<String, ActionError>?

    private var long: Bool { position.quantity > 0 }

    /// Mirrors the Rust validation, for immediate feedback.
    private var problem: String? {
        if takeProfit == nil && stop == nil { return "Set a take-profit, a stop, or both." }
        if let tp = takeProfit, let st = stop, long ? tp <= st : tp >= st {
            return long ? "The take-profit must be above the stop." : "The take-profit must be below the stop."
        }
        if useStopLimit {
            guard let st = stop, let lmt = stopLimit else { return "A stop-limit needs both prices." }
            if long ? lmt > st : lmt < st { return long ? "The stop limit must be at or below the stop." : "The stop limit must be at or above the stop." }
        }
        if let m = mark(store.positionQuote) {
            if let tp = takeProfit, long ? tp <= m : tp >= m { return "The take-profit is on the wrong side of the market (\(m.formatted())); it would fill now." }
            if let st = stop, long ? st >= m : st <= m { return "The stop is on the wrong side of the market (\(m.formatted())); it would trigger now." }
        }
        return nil
    }

    var body: some View {
        let working = store.workingOrders(for: position)
        VStack(alignment: .leading, spacing: 10) {
            Text("Add stop / take-profit").font(.headline)
            if store.strategy(managing: position) != nil || !working.isEmpty {
                Text("This position already has working orders. Edit them above instead, so the exits can't add up to more than the position.")
                    .font(.callout).foregroundStyle(.orange)
                HStack { Spacer(); Button("Back", action: done) }
            } else {
                let exit = long ? "SELL" : "BUY"
                Text("\(exit) \(abs(position.quantity).quantity) \(position.displaySymbol) when either price is reached. Both orders share one OCA group (only one can fill) and stay working until filled or cancelled (GTC).")
                    .font(.callout)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Take-profit")
                        TextField("Limit price", value: $takeProfit, format: .number.precision(.fractionLength(0...4))).frame(width: 110)
                        Text(long ? "limit, above the market" : "limit, below the market").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Stop")
                        TextField("Stop price", value: $stop, format: .number.precision(.fractionLength(0...4))).frame(width: 110)
                        Toggle("Stop-limit", isOn: $useStopLimit)
                    }
                    if useStopLimit {
                        GridRow {
                            Text("Stop limit")
                            TextField("Limit price", value: $stopLimit, format: .number.precision(.fractionLength(0...4))).frame(width: 110)
                            Text("may not fill in a fast market").foregroundStyle(.secondary)
                        }
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
                Text("Account \(store.account) — \(store.isLive ? "LIVE (real money)" : "PAPER")").font(.callout)
                switch outcome {
                case .success(let text): Label("Placed \(text)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure(let error): Label(error.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
                case nil: EmptyView()
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Back", action: done).disabled(busy)
                    Button(store.isLive ? "Place LIVE Orders" : "Place Paper Orders") { submit() }
                        .buttonStyle(.borderedProminent)
                        .tint(store.isLive ? .red : .accentColor)
                        .disabled(problem != nil || busy || isDone)
                }
            }
        }
        .card(padding: 12)
        .onAppear(perform: prefill)
    }

    private var isDone: Bool {
        if case .success = outcome { return true }
        return false
    }

    /// ±10% around the mark, as a starting point.
    private func prefill() {
        guard let m = mark(store.positionQuote) else { return }
        let round = { (v: Double) in (v * 100).rounded() / 100 }
        takeProfit = round(long ? m * 1.1 : m * 0.9)
        stop = round(long ? m * 0.9 : m * 1.1)
    }

    private func submit() {
        busy = true
        outcome = nil
        Task {
            do throws(ActionError) {
                let text = try await store.protectPosition(position, takeProfit: takeProfit, stop: stop,
                                                           stopLimit: useStopLimit ? stopLimit : nil)
                outcome = .success(text)
            } catch {
                outcome = .failure(error)
            }
            busy = false
        }
    }
}
