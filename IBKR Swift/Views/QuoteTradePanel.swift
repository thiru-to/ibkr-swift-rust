import IbkrCore
import SwiftUI

private struct QuoteTradeReview: Identifiable {
    let id = UUID()
    let request: InstrumentOrderRequest
    let closing: Bool
    let held: Double
    let account: String
    let live: Bool
}

struct QuoteTradePanel: View {
    @Environment(AppStore.self) private var store
    @State private var shares = 25
    @State private var limitText = ""
    private var limit: Double? { Double(limitText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    @State private var tif = TimeInForce.day
    @State private var review: QuoteTradeReview?

    private var position: Position? {
        store.positions.first { $0.contractId == store.quoteInstrument?.contractId && $0.account == store.account }
    }
    private var held: Double { position?.quantity ?? 0 }
    private var working: [OrderInfo] {
        store.orders.filter { $0.contractId == store.quoteInstrument?.contractId && $0.account == store.account && $0.group == .open }
    }
    private var tradable: Bool {
        guard let i = store.quoteInstrument else { return false }
        return i.kind == "STK" || i.kind == "ETF"
    }
    private var blocked: Bool { !tradable || store.quoteTradeBusy || store.quoteTradeLocked || store.linkProblem != nil || store.connection != .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Trade").font(.title2.bold())
                    Spacer()
                    ModeBadge(isLive: store.isLive)
                }
                Text(store.account).font(.caption).foregroundStyle(.secondary)
                if tradable {
                    Text("Position: \(held.quantity) shares").font(.headline)
                    Text("\(working.count) working orders").font(.caption).foregroundStyle(.secondary)
                    Text("Shares").font(.caption.bold())
                    Picker("Shares", selection: $shares) {
                        ForEach([25, 100, 250, 500, 1000], id: \.self) { Text(String($0)).tag($0) }
                    }.labelsHidden()
                    tradeButton("Buy Market", side: .buy, kind: .market, color: .green)
                    tradeButton("Sell Market", side: .sell, kind: .market, color: .red)
                    Text("After buy: \((held + Double(shares)).quantity) · After sell: \((held - Double(shares)).quantity) shares")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Limit order").font(.headline)
                    TextField("Limit price", text: $limitText)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Use Bid") { limitText = store.quote?.bid.map { String($0) } ?? "" }.disabled(store.quote?.bid == nil)
                        Button("Use Ask") { limitText = store.quote?.ask.map { String($0) } ?? "" }.disabled(store.quote?.ask == nil)
                    }.font(.caption)
                    Picker("Duration", selection: $tif) {
                        Text("Day").tag(TimeInForce.day)
                        Text("GTC").tag(TimeInForce.gtc)
                    }.pickerStyle(.segmented)
                    tradeButton("Buy Limit", side: .buy, kind: .limit(price: limit ?? 0), color: .green)
                    tradeButton("Sell Limit", side: .sell, kind: .limit(price: limit ?? 0), color: .red)
                    Divider()
                    Button("Close Position — Market") { prepare(side: held > 0 ? .sell : .buy, kind: .market, closing: true) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .disabled(blocked || held == 0 || position.map { store.strategy(managing: $0) != nil } == true)
                    Text("Cancels this app’s working orders first. Orders owned by another client must be cleared there.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Select a stock or ETF to trade. Options and indexes are view-only here.")
                        .foregroundStyle(.secondary)
                }
                if let status = store.quoteTradeStatus { Text(status).font(.caption).textSelection(.enabled) }
                if store.quoteTradeBusy { ProgressView().controlSize(.small) }
            }.padding(.vertical, 4)
        }
        .onChange(of: store.quoteInstrument?.contractId) { _, _ in limitText = ""; review = nil }
        .onChange(of: store.account) { _, _ in review = nil }
        .onChange(of: store.isLive) { _, _ in review = nil }
        .onChange(of: store.connection) { _, _ in review = nil }
        .sheet(item: $review) { r in
            VStack(alignment: .leading, spacing: 16) {
                Text(r.closing ? "Review market close" : "Review order").font(.title2.bold())
                Text("\(r.live ? "LIVE" : "PAPER") · \(r.account)").foregroundStyle(r.live ? .red : .secondary)
                Text("\(r.request.instrument.symbol) · \(r.request.instrument.primaryExchange) · \(r.request.instrument.currency)")
                Text("\(r.request.side == .buy ? "BUY" : "SELL") \(r.request.quantity.quantity) shares · \(kindLabel(r.request.kind, duration: r.request.tif))")
                if r.closing {
                    Text("Cancel this app’s working orders and close the reviewed position. A changed position requires a new review.")
                } else {
                    Text("Estimated resulting position: \((r.held + (r.request.side == .buy ? r.request.quantity : -r.request.quantity)).quantity) shares")
                }
                ForEach(OrderCheck.warnings(OrderRequest(symbol: r.request.instrument.symbol, side: r.request.side, quantity: r.request.quantity, kind: r.request.kind, tif: r.request.tif), store.quote, netLiquidation: store.summary?.netLiquidation), id: \.self) { warning in
                    Text(warning).font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Cancel") { review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Submit \(r.live ? "LIVE" : "paper") order") { review = nil; send(r) }
                        .disabled(blocked)
                }
            }.padding(24).frame(width: 460)
        }
    }

    private func kindLabel(_ kind: OrderKind, duration: TimeInForce) -> String {
        switch kind { case .market: "Market · Day"; case .limit(let price): "Limit \(price.formatted()) · \(duration == .day ? "Day" : "GTC")" }
    }
    private func tradeButton(_ title: String, side: OrderSide, kind: OrderKind, color: Color) -> some View {
        Button { prepare(side: side, kind: kind, closing: false) } label: {
            Text("\(title) · \(shares)").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).tint(color).controlSize(.large)
            .disabled(blocked || invalid(kind))
    }
    private func invalid(_ kind: OrderKind) -> Bool {
        if case .limit(let price) = kind { return !price.isFinite || price <= 0 }
        return false
    }
    private func prepare(side: OrderSide, kind: OrderKind, closing: Bool) {
        guard !blocked, let i = store.quoteInstrument else { return }
        let request = InstrumentOrderRequest(instrument: i, side: side, quantity: closing ? abs(held) : Double(shares), kind: kind, tif: closing || kind == .market ? .day : tif)
        let action = QuoteTradeReview(request: request, closing: closing, held: held, account: store.account, live: store.isLive)
        if store.isLive { review = action } else { send(action) }
    }
    private func send(_ action: QuoteTradeReview) {
        Task { await store.submitQuoteTrade(action.request, closeQuantity: action.held, closing: action.closing, reviewedAccount: action.account, reviewedLive: action.live) }
    }
}
