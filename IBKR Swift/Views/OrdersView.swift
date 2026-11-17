//
//  OrdersView.swift
//  IBKR Swift
//
//  Order ticket + order list. Every submit goes through a confirmation sheet that
//  shows the account and LIVE/PAPER mode; keep it that way. The sheet then shows IB's
//  answer (accepted with live status, or the rejection reason).
//

import IbkrCore
import SwiftUI

struct OrdersView: View {
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "New order", icon: "square.and.pencil", tint: .orange)
                    .padding(.horizontal, 20).padding(.top, 20)
                OrderTicketView()
            }
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320)
            OrderListView()
                .frame(minWidth: 420)
        }
        .navigationTitle("Orders")
    }
}

struct OrderTicketView: View {
    @Environment(AppStore.self) private var store

    @State private var symbol = ""
    @State private var side = OrderSide.buy
    @State private var quantity: Double?
    @State private var isLimit = true
    @State private var limitPrice: Double?
    @State private var tif = TimeInForce.day
    @State private var reviewing: OrderRequest?

    private var request: OrderRequest? {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty, let quantity, quantity > 0 else { return nil }
        let kind: OrderKind
        if isLimit {
            guard let limitPrice, limitPrice > 0 else { return nil }
            kind = .limit(price: limitPrice)
        } else {
            kind = .market
        }
        return OrderRequest(symbol: symbol, side: side, quantity: quantity, kind: kind, tif: tif)
    }

    /// The ticket quote, if it's for the symbol being typed.
    private var quote: Quote? {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        return store.ticketQuote.flatMap { $0.symbol == symbol ? $0 : nil }
    }

    private var sending: Bool {
        if case .sending = store.lastPlacement?.state { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                TextField("Symbol", text: $symbol)
                if let quote { QuoteStrip(quote: quote) }
                Picker("Side", selection: $side) {
                    Text("Buy").tag(OrderSide.buy)
                    Text("Sell").tag(OrderSide.sell)
                }
                .pickerStyle(.segmented)
                TextField("Quantity", value: $quantity, format: .number)
                Picker("Type", selection: $isLimit) {
                    Text("Limit").tag(true)
                    Text("Market").tag(false)
                }
                .pickerStyle(.segmented)
                if isLimit {
                    TextField("Limit Price", value: $limitPrice, format: .number.precision(.fractionLength(0...4)))
                }
                Picker("Time in Force", selection: $tif) {
                    Text("Day").tag(TimeInForce.day)
                    Text("GTC").tag(TimeInForce.gtc)
                }
            }

            Section {
                if let request, let value = OrderCheck.estimatedValue(request, quote) {
                    LabeledContent("Est. value", value: Optional(value).money("USD"))
                        .monospacedDigit()
                }
                Button {
                    reviewing = request
                } label: {
                    Text(side == .buy ? "Review Buy…" : "Review Sell…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(side == .buy ? .green : .red)
                .controlSize(.large)
                .disabled(request == nil || sending)
            }

            if let placement = store.lastPlacement {
                Section("Last order") {
                    PlacementSummary(placement: placement)
                }
            }
        }
        .formStyle(.grouped)
        // Debounced so typing a symbol doesn't open a market-data line per keystroke.
        .task(id: symbol) {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
            store.watchTicketQuote(symbol: symbol)
        }
        .sheet(item: $reviewing) { request in
            OrderConfirmSheet(request: request)
        }
    }
}

/// Bid × ask and last for the ticket.
private struct QuoteStrip: View {
    let quote: Quote

    var body: some View {
        HStack(spacing: 6) {
            Text(quote.bid.formatted()).foregroundStyle(.red)
            Text("×").foregroundStyle(.secondary)
            Text(quote.ask.formatted()).foregroundStyle(.green)
            Spacer()
            Text("Last \(quote.last.formatted())").foregroundStyle(.secondary)
            if quote.delayed { Pill(text: "DELAYED", color: .orange) }
        }
        .font(.callout)
        .monospacedDigit()
    }
}

nonisolated extension OrderRequest: @retroactive Identifiable {
    public var id: String { "\(symbol)-\(side)-\(quantity)-\(kind)-\(tif)" }
}

/// Sanity checks shown before submitting: catches typos like 1500 for 150.00 and
/// orders that are a large share of the account.
enum OrderCheck {
    /// Shares × the price it would fill near (limit, else ask/bid, else last).
    static func estimatedValue(_ r: OrderRequest, _ q: Quote?) -> Double? {
        let price: Double? = switch r.kind {
        case .limit(let price): price
        case .market: (r.side == .buy ? q?.ask : q?.bid) ?? q?.last
        }
        return price.map { $0 * r.quantity }
    }

    static func warnings(_ r: OrderRequest, _ q: Quote?, netLiquidation: Double?) -> [String] {
        var out: [String] = []
        let reference = q?.last ?? q.flatMap { q in q.bid.flatMap { b in q.ask.map { (b + $0) / 2 } } }
        guard let q, let reference, reference > 0 else {
            return ["No quote for \(r.symbol) — check the price yourself."]
        }
        if q.delayed { out.append("The quote is delayed (about 15 minutes).") }

        switch r.kind {
        case .market:
            if let bid = q.bid, let ask = q.ask, bid > 0, (ask - bid) / reference > 0.01 {
                out.append("Wide spread (\(bid.formatted()) × \(ask.formatted())); a market order can fill far from the last price.")
            }
        case .limit(let price):
            let through = r.side == .buy ? (price - (q.ask ?? reference)) : ((q.bid ?? reference) - price)
            if through / reference > 0.05 {
                let pct = (through / reference).formatted(.percent.precision(.fractionLength(0)))
                out.append("The limit is \(pct) \(r.side == .buy ? "above the ask" : "below the bid"); it will fill like a market order.")
            } else if abs(price - reference) / reference > 0.2 {
                out.append("The limit is far from the last price (\(reference.formatted())); check for a typo.")
            }
        }

        if let value = estimatedValue(r, q), let netLiquidation, netLiquidation > 0, value / netLiquidation > 0.25 {
            let pct = (value / netLiquidation).formatted(.percent.precision(.fractionLength(0)))
            out.append("This order is about \(pct) of net liquidation.")
        }
        return out
    }

    static func describe(_ r: OrderRequest) -> String {
        let type: String = switch r.kind {
        case .market: "Market"
        case .limit(let price): "Limit \(price.formatted(.number.precision(.fractionLength(2...4))))"
        }
        return "\(type) · \(r.tif == .day ? "Day" : "GTC")"
    }
}

/// Review → send → IB's answer, in one sheet.
private struct OrderConfirmSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: OrderRequest
    @State private var placementId: UUID?

    private var quote: Quote? {
        store.ticketQuote.flatMap { $0.symbol == request.symbol ? $0 : nil }
    }

    /// Set once this sheet has submitted.
    private var placement: Placement? {
        store.lastPlacement.flatMap { $0.id == placementId ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(placement == nil ? "Confirm Order" : "Order").font(.title2.bold())
                Spacer()
                ModeBadge(isLive: store.isLive)
            }

            OrderHeadline(request: request)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Type", OrderCheck.describe(request))
                if let quote {
                    row("Market", "\(quote.bid.formatted()) × \(quote.ask.formatted()) · last \(quote.last.formatted())\(quote.delayed ? " (delayed)" : "")")
                }
                if let value = OrderCheck.estimatedValue(request, quote) {
                    row("Est. value", Optional(value).money("USD"))
                }
                row("Account", "\(store.account) — \(store.isLive ? "LIVE (real money)" : "PAPER")")
            }
            .monospacedDigit()

            if let placement {
                PlacementResult(placement: placement)
            } else {
                if let riskProblem {
                    Label(riskProblem, systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .card(padding: 10)
                }
                let warnings = OrderCheck.warnings(request, quote, netLiquidation: store.summary?.netLiquidation)
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill") }
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .card(padding: 10)
                }
            }

            HStack {
                Spacer()
                if placement == nil {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    // Deliberately no Return shortcut: submitting takes a click.
                    Button(store.isLive ? "Submit LIVE Order" : "Submit Paper Order") { submit() }
                        .buttonStyle(.borderedProminent)
                        .tint(store.isLive ? .red : .accentColor)
                        .disabled(riskProblem != nil)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSending)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var isSending: Bool {
        if case .sending = placement?.state { return true }
        return false
    }

    /// Only the part that opens or adds to a position is checked against the risk limits,
    /// so selling a long or buying back a short always works, even while halted. The Rust
    /// side re-checks against IB's position and working orders.
    private var riskProblem: String? {
        let opening = store.openingQuantity(symbol: request.symbol, side: request.side, quantity: request.quantity)
        guard opening > 0 else { return nil }
        let cost = OrderCheck.estimatedValue(request, quote).map { $0 / request.quantity * opening }
        return store.entryProblem(cost: cost)
    }

    private func submit() {
        placementId = store.placeOrder(request)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// "BUY 100 AAPL", large and colored by side.
private struct OrderHeadline: View {
    let request: OrderRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(request.side == .buy ? "BUY" : "SELL")
                .foregroundStyle(request.side == .buy ? .green : .red)
            Text(request.quantity.quantity)
            Text(request.symbol)
        }
        .font(.system(size: 28, weight: .bold, design: .rounded))
        .monospacedDigit()
    }
}

/// IB's answer plus the order's live status from the order list.
private struct PlacementResult: View {
    @Environment(AppStore.self) private var store
    let placement: Placement

    var body: some View {
        switch placement.state {
        case .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending to IB…")
            }
            .card(padding: 12)
        case .accepted(let placed):
            let live = store.order(placed)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Order #\(String(placed.orderId)) accepted by IB", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Spacer()
                    if let live { StatusPill(order: live) } else { Pill(text: placed.status.uppercased(), color: .blue) }
                }
                if let live, live.filled > 0 {
                    Text("Filled \(live.filled.quantity) of \(live.quantity.quantity) @ \(live.averageFillPrice.formatted(digits: 4))")
                        .monospacedDigit()
                }
                if let live, !live.detail.isEmpty {
                    Text(live.detail).font(.callout).foregroundStyle(.secondary)
                } else if !placed.message.isEmpty {
                    Text(placed.message).font(.callout).foregroundStyle(.orange)
                }
                if placed.status == "Sent" && live == nil {
                    Text("IB hasn't confirmed yet; it will appear in the order list when it does.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .card(padding: 12)
        case .rejected(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Not placed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.headline)
                Text(reason).textSelection(.enabled)
            }
            .card(padding: 12)
        }
    }
}

/// Compact version for the ticket's "Last order" section.
private struct PlacementSummary: View {
    @Environment(AppStore.self) private var store
    let placement: Placement

    var body: some View {
        let r = placement.request
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(r.side == .buy ? "BUY" : "SELL") \(r.quantity.quantity) \(r.symbol)")
                    .font(.headline)
                    .foregroundStyle(r.side == .buy ? .green : .red)
                Spacer()
                switch placement.state {
                case .sending: ProgressView().controlSize(.small)
                case .accepted(let placed):
                    if let live = store.order(placed) { StatusPill(order: live) } else { Pill(text: placed.status.uppercased(), color: .blue) }
                case .rejected: Pill(text: "REJECTED", color: .red)
                }
            }
            Text(OrderCheck.describe(r)).font(.callout).foregroundStyle(.secondary)
            switch placement.state {
            case .accepted(let placed):
                if let live = store.order(placed), live.filled > 0 {
                    Text("Filled \(live.filled.quantity) @ \(live.averageFillPrice.formatted(digits: 4))").font(.callout)
                }
            case .rejected(let reason):
                Text(reason).font(.callout).foregroundStyle(.red).lineLimit(3).help(reason)
            case .sending:
                EmptyView()
            }
        }
        .monospacedDigit()
    }
}

/// Filter for the order list. `nil` group = all orders.
private enum OrderFilter: Hashable, CaseIterable {
    case open, filled, cancelled, inactive, other, all

    var group: OrderStatusGroup? {
        switch self {
        case .open: .open
        case .filled: .filled
        case .cancelled: .cancelled
        case .inactive: .inactive
        case .other: .other
        case .all: nil
        }
    }

    var title: String {
        switch self {
        case .open: "Open"
        case .filled: "Filled"
        case .cancelled: "Cancelled"
        case .inactive: "Inactive"
        case .other: "Other"
        case .all: "All"
        }
    }
}

struct OrderListView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = OrderFilter.open
    /// Clicking a row opens its details.
    @State private var selection: OrderInfo.ID?
    @State private var detail: OrderRef?

    var body: some View {
        // Group once per snapshot, rather than scanning the order book for every filter label.
        let groups = Dictionary(grouping: store.orders, by: \.group)
        let counts = groups.mapValues(\.count)
        let shown = filter.group.map { groups[$0] ?? [] } ?? store.orders
        VStack(spacing: 0) {
            PnLTallyView()
            Divider()
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    statusPicker(counts: counts)
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    statusPicker(counts: counts).pickerStyle(.menu)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { store.refreshOrders() }
                    .labelStyle(.iconOnly)
                    .help("Reload open and today's completed orders from IB")
            }
            .padding(12)

            Table(shown, selection: $selection) {
                TableColumn("Symbol") { o in Text(o.displaySymbol).monospaced().fontWeight(.medium) }
                    .width(min: 100, ideal: 150)
                TableColumn("Status") { o in StatusPill(order: o) }.width(min: 100, ideal: 120)
                TableColumn("Order") { o in
                    HStack(spacing: 4) {
                        Text(o.action.uppercased()).fontWeight(.semibold).foregroundStyle(o.isBuy ? .green : .red)
                        Text(o.orderType).foregroundStyle(.secondary)
                    }
                }
                .width(85)
                TableColumn("Filled/Qty") { o in Text("\(o.filled.quantity)/\(o.quantity.quantity)") }.width(65)
                TableColumn("Price") { o in Text(price(o)) }.width(min: 60, ideal: 90)
                TableColumn("Avg Fill") { o in Text(o.averageFillPrice.formatted(digits: 2)) }.width(60)
                TableColumn("Time") { o in Text(time(o.completedTime)).foregroundStyle(.secondary) }.width(65)
                TableColumn("ID") { o in Text(o.orderId > 0 ? String(o.orderId) : "—").foregroundStyle(.secondary) }.width(45)
                TableColumn("Detail") { o in
                    Text(o.detail.replacingOccurrences(of: "\n", with: " "))
                        .foregroundStyle(o.group == .inactive ? .red : .secondary)
                        .help(o.detail)
                }
                TableColumn("") { o in
                    if store.canCancel(o) {
                        Button("Cancel") { Task { await store.cancelOrder(o.orderId) } }
                            .controlSize(.small)
                    } else if o.group == .open && o.clientId != store.sessionClientId {
                        Text("client \(String(o.clientId))").font(.caption).foregroundStyle(.secondary)
                            .help("Placed by another API client or TWS; cancel it there.")
                    }
                }
                .width(70)
            }
            .monospacedDigit()
            .onChange(of: selection) {
                guard let id = selection, let o = store.orders.first(where: { $0.id == id }) else { return }
                detail = OrderRef(o)
            }
            .sheet(item: $detail, onDismiss: { selection = nil }) { ref in
                OrderDetailView(ref: ref)
            }
            .overlay {
                if shown.isEmpty {
                    WorkspaceEmptyState(title: "No \(filter == .all ? "" : filter.title.lowercased() + " ")orders", icon: "tray",
                        description: "Orders reported by IB Gateway will appear here.", tint: .orange)
                }
            }
        }
    }

    private func statusPicker(counts: [OrderStatusGroup: Int]) -> some View {
        Picker("Status", selection: $filter) {
            ForEach(OrderFilter.allCases.filter { $0 != .other || counts[.other, default: 0] > 0 }, id: \.self) { f in
                Text("\(f.title) (\(f.group.map { counts[$0, default: 0] } ?? store.orders.count))").tag(f)
            }
        }.labelsHidden()
    }

    /// Limit and/or stop, e.g. "1.39", "stp 1.13", "stp 1.13 lmt 1.08".
    private func price(_ o: OrderInfo) -> String {
        switch (o.stopPrice, o.limitPrice) {
        case let (stop?, limit?): "stp \(Optional(stop).formatted()) lmt \(Optional(limit).formatted())"
        case let (stop?, nil): "stp \(Optional(stop).formatted())"
        case let (nil, limit?): Optional(limit).formatted()
        case (nil, nil): "—"
        }
    }

    /// IB sends "YYYYMMDD HH:MM:SS TZ"; show the time part.
    private func time(_ completed: String) -> String {
        let parts = completed.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }
}

struct StatusPill: View {
    let order: OrderInfo

    var body: some View {
        let color: Color = switch order.group {
        case .open: .blue
        case .filled: .green
        case .cancelled: .gray
        case .inactive: .red
        case .other: .orange
        }
        // A cancelled order that partly filled is worth calling out.
        let partial = order.group != .filled && order.filled > 0
        Pill(text: order.status.uppercased() + (partial ? " · PARTIAL" : ""), color: color)
    }
}
