//
//  OrdersView.swift
//  IBKR Swift
//
//  Order ticket + open orders. Every submit goes through a confirmation dialog that
//  shows the account and LIVE/PAPER mode; keep it that way.
//

import IbkrCore
import SwiftUI

struct OrdersView: View {
    var body: some View {
        HSplitView {
            OrderTicketView()
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
            OrderListView()
                .frame(minWidth: 380)
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
    @State private var confirming = false
    @State private var submitting = false
    @State private var lastOrderId: Int32?

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

    var body: some View {
        Form {
            TextField("Symbol", text: $symbol)
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

            Section {
                Button(side == .buy ? "Review Buy…" : "Review Sell…") { confirming = true }
                    .disabled(request == nil || submitting)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if let lastOrderId {
                    Text("Submitted order #\(String(lastOrderId))").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Confirm Order", isPresented: $confirming, presenting: request) { request in
            Button(store.isLive ? "Submit LIVE Order" : "Submit Paper Order",
                   role: store.isLive ? .destructive : nil) {
                submit(request)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("\(describe(request))\n\nAccount \(store.account) — \(store.isLive ? "LIVE (real money)" : "PAPER")")
        }
    }

    private func submit(_ request: OrderRequest) {
        submitting = true
        Task {
            lastOrderId = await store.placeOrder(request)
            submitting = false
        }
    }

    private func describe(_ r: OrderRequest) -> String {
        let action = r.side == .buy ? "BUY" : "SELL"
        let type: String = switch r.kind {
        case .market: "MKT"
        case .limit(let price): "LMT \(price.formatted(.number.precision(.fractionLength(2...4))))"
        }
        return "\(action) \(r.quantity.quantity) \(r.symbol) \(type) \(r.tif == .day ? "DAY" : "GTC")"
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

    private func count(_ f: OrderFilter) -> Int {
        guard let group = f.group else { return store.orders.count }
        return store.orders.filter { $0.group == group }.count
    }

    private var shown: [OrderInfo] {
        guard let group = filter.group else { return store.orders }
        return store.orders.filter { $0.group == group }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Status", selection: $filter) {
                    // "Other" only when IB sent a status ibapi doesn't model.
                    ForEach(OrderFilter.allCases.filter { $0 != .other || count(.other) > 0 }, id: \.self) { f in
                        Text("\(f.title) (\(count(f)))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Refresh", systemImage: "arrow.clockwise") { store.refreshOrders() }
                    .labelStyle(.iconOnly)
                    .help("Reload open and today's completed orders from IB")
            }
            .padding(8)

            Table(shown) {
                TableColumn("ID") { o in Text(o.orderId > 0 ? String(o.orderId) : "—") }.width(45)
                TableColumn("Time") { o in Text(time(o.completedTime)) }.width(65)
                TableColumn("Symbol") { o in
                    // Options share a symbol; show IB's full contract name for them.
                    Text(o.secType == "STK" || o.localSymbol.isEmpty ? o.symbol : o.localSymbol).monospaced()
                }
                .width(min: 90, ideal: 170)
                TableColumn("Order") { o in Text("\(o.action) \(o.orderType)") }.width(75)
                TableColumn("Filled/Qty") { o in Text("\(o.filled.quantity)/\(o.quantity.quantity)") }.width(65)
                TableColumn("Price") { o in Text(price(o)) }.width(min: 60, ideal: 90)
                TableColumn("Avg Fill") { o in Text(o.averageFillPrice.formatted()) }.width(60)
                TableColumn("Status") { o in StatusLabel(order: o) }.width(min: 80, ideal: 100)
                TableColumn("Detail") { o in
                    Text(o.detail.replacingOccurrences(of: "\n", with: " "))
                        .foregroundStyle(.secondary)
                        .help(o.detail)
                }
                TableColumn("") { o in
                    if o.group == .open && o.orderId > 0 {
                        Button("Cancel") { Task { await store.cancelOrder(o.orderId) } }
                            .disabled(o.status == "PendingCancel")
                    }
                }
                .width(65)
            }
            .monospacedDigit()
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("No \(filter == .all ? "" : filter.title + " ")Orders", systemImage: "tray")
                }
            }
        }
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

private struct StatusLabel: View {
    let order: OrderInfo

    var body: some View {
        let color: Color = switch order.group {
        case .open: .blue
        case .filled: .green
        case .cancelled: .secondary
        case .inactive: .red
        case .other: .orange
        }
        // A cancelled order that partly filled is worth calling out.
        let partial = order.group != .filled && order.filled > 0
        Text(order.status + (partial ? " (partial)" : ""))
            .foregroundStyle(color)
    }
}
