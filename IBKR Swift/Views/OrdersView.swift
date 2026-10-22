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
            OpenOrdersView()
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

struct OpenOrdersView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Table(store.orders) {
            TableColumn("ID") { o in Text(String(o.orderId)) }.width(60)
            TableColumn("Symbol", value: \.symbol)
            TableColumn("Side", value: \.action).width(50)
            TableColumn("Type", value: \.orderType).width(50)
            TableColumn("Qty") { o in Text("\(o.filled.quantity)/\(o.quantity.quantity)") }
            TableColumn("Limit") { o in Text(o.limitPrice.formatted()) }
            TableColumn("Status", value: \.status)
            TableColumn("") { o in
                Button("Cancel") { Task { await store.cancelOrder(o.orderId) } }
                    .disabled(o.status == "PendingCancel")
            }
            .width(70)
        }
        .monospacedDigit()
        .overlay {
            if store.orders.isEmpty {
                ContentUnavailableView("No Open Orders", systemImage: "tray")
            }
        }
    }
}
