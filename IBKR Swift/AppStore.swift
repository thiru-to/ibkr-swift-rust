//
//  AppStore.swift
//  IBKR Swift
//
//  App state. Everything here is MainActor (the target's default isolation); Rust
//  stream callbacks arrive on Rust threads and are hopped to the main queue by the
//  listener sinks at the bottom of this file.
//

import Foundation
import IbkrCore
import Observation

@Observable
final class AppStore {
    enum Connection: Equatable {
        case disconnected, connecting, connected
    }

    enum TradingMode: String, CaseIterable, Identifiable {
        case live, paper

        var id: Self { self }
        var title: String { self == .live ? "Live" : "Paper" }
        /// IB Gateway defaults.
        var defaultPort: Int { self == .live ? 4001 : 4002 }
    }

    /// Selecting a mode sets the port; the choice is remembered across launches.
    var mode: TradingMode {
        didSet {
            port = mode.defaultPort
            UserDefaults.standard.set(mode.rawValue, forKey: "tradingMode")
        }
    }

    var host = "127.0.0.1"
    var port: Int
    var clientId = 1

    private(set) var connection = Connection.disconnected
    private(set) var account = ""
    private(set) var isLive = false
    /// This connection's client id; order ids are only unique per client.
    private(set) var sessionClientId: Int32 = 0
    /// Set while the Gateway link is down (ibapi reconnects on its own).
    private(set) var linkProblem: String?

    private(set) var summary: AccountSummary?
    private(set) var positions: [Position] = []
    private(set) var quote: Quote?
    /// Price bars for the Quote screen's chart.
    private(set) var history: [PriceBar] = []
    private(set) var loadingHistory = false
    private(set) var loadingOlderHistory = false
    /// Bumped on each fresh load (not on pages of older bars), so the chart knows to reset.
    private(set) var historySeries = 0
    /// Working orders plus today's completed ones, newest first.
    private(set) var orders: [OrderInfo] = []
    /// The ticket's most recent order and IB's answer to it.
    private(set) var lastPlacement: Placement?
    private(set) var ticketQuote: Quote?
    /// Quote for the position open in the details sheet.
    private(set) var positionQuote: Quote?
    private(set) var toasts: [Toast] = []
    var lastError: String?

    // Options
    private(set) var chain: OptionChain?
    private(set) var loadingChain = false
    private(set) var underlyingQuote: Quote?
    private(set) var optionQuote: Quote?
    private(set) var strategyUpdates: [UInt64: StrategyUpdate] = [:]
    /// What was armed, for display (the Rust side only reports progress).
    private(set) var strategySpecs: [UInt64: StrategySpec] = [:]
    @ObservationIgnored private var strategyHandles: [UInt64: StrategyHandle] = [:]

    var strategies: [StrategyUpdate] {
        strategyUpdates.values.sorted { $0.id > $1.id }
    }

    /// Strategies that stop working if the app quits or disconnects.
    var appDependentStrategies: Int {
        strategyUpdates.values.filter(\.requiresApp).count
    }

    var openOrderCount: Int { orders.filter { $0.group == .open }.count }
    var activeStrategyCount: Int {
        strategyUpdates.values.filter { ![.closed, .disarmed, .failed].contains($0.state) }.count
    }

    @ObservationIgnored private var session: IbkrSession?
    @ObservationIgnored private var streams: [String: StreamHandle] = [:]
    /// What each quote stream is watching, to re-request after Gateway drops market data.
    @ObservationIgnored private var watched: [String: String] = [:]
    @ObservationIgnored private var watchedOption: OptionSpec?
    @ObservationIgnored private var watchedContract: Int32?
    /// The latest history request; older answers are dropped.
    @ObservationIgnored private var historyRequest = 0
    /// What `history` holds, for paging back.
    @ObservationIgnored private var historyKey: (symbol: String, range: ChartRange, interval: BarInterval)?
    /// IB had nothing older (or failed); stop paging until the next fresh load.
    @ObservationIgnored private var historyExhausted = false
    @ObservationIgnored private var lastOlderHistory: ContinuousClock.Instant?
    /// Group and fill per order id from the previous snapshot; nil until the first one,
    /// which is the baseline (no toasts for orders that were already done).
    @ObservationIgnored private var orderMemory: [String: (group: OrderStatusGroup, filled: Double)]?

    init() {
        let mode = UserDefaults.standard.string(forKey: "tradingMode").flatMap(TradingMode.init) ?? .paper
        self.mode = mode
        self.port = mode.defaultPort
    }

    // MARK: Connection

    func connect() async {
        guard connection == .disconnected, let port = UInt16(exactly: port) else { return }
        connection = .connecting
        lastError = nil
        do {
            let session = try await IbkrCore.connect(host: host, port: port, clientId: Int32(clientId))
            self.session = session
            account = session.account()
            sessionClientId = session.clientId()
            // IB paper account ids start with "D" (e.g. DU1234567). Treat the session as
            // live if anything says so: the selected mode, the port, or the account id.
            let liveAccount = !account.hasPrefix("D")
            isLive = mode == .live || session.isLive() || liveAccount
            if mode == .paper && isLive {
                lastError = "Paper mode is selected, but Gateway reports a live account (\(account)). Orders will use real money."
            }
            connection = .connected
            startStreams(session)
            await refreshSummary()
        } catch {
            connection = .disconnected
            report(error)
        }
    }

    func disconnect() async {
        streams.values.forEach { $0.cancel() }
        streams.removeAll()
        if let session {
            try? await session.disconnect()
        }
        session = nil
        connection = .disconnected
        account = ""
        linkProblem = nil
        summary = nil
        positions = []
        quote = nil
        history = []
        ticketQuote = nil
        positionQuote = nil
        watched.removeAll()
        watchedOption = nil
        watchedContract = nil
        orders = []
        orderMemory = nil
        lastPlacement = nil
        chain = nil
        underlyingQuote = nil
        optionQuote = nil
        strategyHandles.removeAll()
        strategyUpdates.removeAll()
        strategySpecs.removeAll()
    }

    private func startStreams(_ session: IbkrSession) {
        streams["link"] = session.subscribeConnection(listener: ConnectionSink { [weak self] in
            self?.linkChanged($0, $1)
        })
        streams["positions"] = session.subscribePositions(listener: PositionsSink(
            update: { [weak self] in self?.positions = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
        refreshOrders()
    }

    /// Re-subscribes, which reloads open and today's completed orders from IB.
    func refreshOrders() {
        guard let session else { return }
        streams["orders"]?.cancel()
        streams["orders"] = session.subscribeOrders(listener: OrdersSink(
            update: { [weak self] in self?.ordersChanged($0) },
            fail: { [weak self] in self?.lastError = $0 }
        ))
    }

    private func linkChanged(_ status: LinkStatus, _ message: String) {
        switch status {
        case .lost:
            linkProblem = message
        case .restored, .restoredDataLost:
            if linkProblem != nil {
                post(Toast(title: "Connection restored", detail: "Orders and positions reloaded from IB.", tone: .success))
            }
            linkProblem = nil
            if status == .restoredDataLost { resubscribeQuotes() }
        }
    }

    /// Market-data subscriptions don't survive a Gateway reconnect; orders and
    /// positions resubscribe on the Rust side.
    private func resubscribeQuotes() {
        guard let session else { return }
        for (key, symbol) in watched {
            streams[key] = session.subscribeQuote(symbol: symbol, listener: quoteSink(key))
        }
        if let watchedOption { watchOption(watchedOption) }
        if let watchedContract { watchPosition(contractId: watchedContract) }
    }

    /// Posts a toast for each order that filled, partly filled, or was cancelled or
    /// rejected since the last snapshot.
    private func ordersChanged(_ new: [OrderInfo]) {
        orders = new
        let memory = Dictionary(new.map { ($0.id, (group: $0.group, filled: $0.filled)) }, uniquingKeysWith: { a, _ in a })
        defer { orderMemory = memory }
        guard let previous = orderMemory else { return }
        for o in new {
            let before = previous[o.id] ?? (group: .open, filled: 0)
            let what = "\(o.action.uppercased()) \(o.quantity.quantity) \(o.displaySymbol)"
            if o.group == .filled && before.group != .filled {
                post(Toast(title: "Filled", detail: "\(what) @ \(o.averageFillPrice.formatted(digits: 2))", tone: .success))
            } else if o.group == .open && o.filled > before.filled {
                post(Toast(title: "Partially filled", detail: "\(what): \(o.filled.quantity) done @ \(o.averageFillPrice.formatted(digits: 2))", tone: .info))
            } else if o.group != before.group && (o.group == .inactive || o.group == .cancelled) {
                let reason = o.detail.isEmpty ? "" : " — \(o.detail)"
                let rejected = o.group == .inactive
                post(Toast(title: rejected ? "Rejected" : "Cancelled", detail: what + reason, tone: rejected ? .failure : .info))
            }
        }
    }

    // MARK: Toasts

    func post(_ toast: Toast) {
        toasts.append(toast)
        if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(toast.tone == .failure ? 15 : 6))
            dismissToast(id)
        }
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: Data

    func refreshSummary() async {
        guard let session else { return }
        do {
            summary = try await session.accountSummary()
        } catch {
            report(error)
        }
    }

    func watchQuote(symbol: String) {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard let session, !symbol.isEmpty else { return }
        streams["quote"]?.cancel()
        quote = Quote(symbol: symbol, bid: nil, ask: nil, last: nil, close: nil,
                      bidSize: nil, askSize: nil, volume: nil, delayed: false)
        watched["quote"] = symbol
        streams["quote"] = session.subscribeQuote(symbol: symbol, listener: quoteSink("quote"))
    }

    /// Loads chart bars for `symbol`. Answers to superseded requests are ignored.
    func loadHistory(symbol: String, range: ChartRange, interval: BarInterval) async {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard let session, !symbol.isEmpty else { return }
        historyRequest += 1
        let request = historyRequest
        historyKey = (symbol, range, interval)
        historyExhausted = false
        loadingHistory = true
        do {
            let bars = try await session.priceHistory(symbol: symbol, range: range, interval: interval, end: nil)
            guard request == historyRequest else { return }
            history = bars
        } catch {
            guard request == historyRequest else { return }
            history = []
            report(error)
        }
        historySeries += 1
        loadingHistory = false
    }

    /// Prepends the page of bars before the oldest one shown. Paced well inside IB's
    /// historical-data limits: one request at a time, at most one every 3s, each for a
    /// different window, and none once IB runs out of data.
    func loadOlderHistory() async {
        guard let session, let key = historyKey, let oldest = history.first,
              !loadingHistory, !loadingOlderHistory, !historyExhausted else { return }
        let now = ContinuousClock.now
        if let last = lastOlderHistory, now - last < .seconds(3) { return }
        lastOlderHistory = now
        let request = historyRequest
        loadingOlderHistory = true
        defer { loadingOlderHistory = false }
        do {
            let older = try await session.priceHistory(symbol: key.symbol, range: key.range,
                                                       interval: key.interval, end: oldest.time)
            guard request == historyRequest else { return }
            if older.isEmpty { historyExhausted = true } else { history = older + history }
        } catch {
            guard request == historyRequest else { return }
            // Typically IB's "no data" at the start of a stock's history.
            historyExhausted = true
            report(error)
        }
    }

    /// Live quote for the order ticket's symbol.
    func watchTicketQuote(symbol: String) {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard watched["ticket"] != symbol else { return }
        streams["ticket"]?.cancel()
        ticketQuote = nil
        watched["ticket"] = nil
        guard let session, !symbol.isEmpty else { return }
        watched["ticket"] = symbol
        streams["ticket"] = session.subscribeQuote(symbol: symbol, listener: quoteSink("ticket"))
    }

    /// Live quote for a position's contract; nil stops it.
    func watchPosition(contractId: Int32?) {
        streams["position"]?.cancel()
        positionQuote = nil
        watchedContract = contractId
        guard let session, let contractId else { return }
        streams["position"] = session.subscribeContractQuote(contractId: contractId, listener: quoteSink("position"))
    }

    /// Routes a quote stream to its property by stream key.
    private func quoteSink(_ key: String) -> QuoteSink {
        QuoteSink(
            update: { [weak self] q in
                switch key {
                case "quote": self?.quote = q
                case "ticket": self?.ticketQuote = q
                case "underlying": self?.underlyingQuote = q
                case "position": self?.positionQuote = q
                default: break
                }
            },
            fail: { [weak self] in self?.lastError = $0 }
        )
    }

    // MARK: Options

    /// Loads the chain and starts streaming the underlying.
    func loadChain(symbol: String) async {
        let symbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard let session, !symbol.isEmpty else { return }
        loadingChain = true
        defer { loadingChain = false }
        streams["underlying"]?.cancel()
        underlyingQuote = nil
        watched["underlying"] = symbol
        streams["underlying"] = session.subscribeQuote(symbol: symbol, listener: quoteSink("underlying"))
        do {
            chain = try await session.optionChain(symbol: symbol)
        } catch {
            chain = nil
            report(error)
        }
    }

    func watchOption(_ option: OptionSpec?) {
        streams["option"]?.cancel()
        optionQuote = nil
        watchedOption = option
        guard let session, let option else { return }
        streams["option"] = session.subscribeOptionQuote(option: option, listener: QuoteSink(
            update: { [weak self] in self?.optionQuote = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
    }

    func arm(_ spec: StrategySpec) {
        guard let session else { return }
        var spec = spec
        if isLive { spec.allowDelayed = false }
        let handle = session.armStrategy(spec: spec, listener: StrategySink(
            update: { [weak self] in self?.strategyUpdates[$0.id] = $0 }
        ))
        strategyHandles[handle.id()] = handle
        strategySpecs[handle.id()] = spec
    }

    func disarm(_ id: UInt64) {
        strategyHandles[id]?.disarm()
    }

    func closeNow(_ id: UInt64) {
        strategyHandles[id]?.closeNow()
    }

    /// Removes a finished strategy from the list.
    func dismissStrategy(_ id: UInt64) {
        strategyHandles[id] = nil
        strategyUpdates[id] = nil
        strategySpecs[id] = nil
    }

    // MARK: Positions

    /// A running strategy that can close this position through its own OCA group.
    func strategy(managing p: Position) -> StrategyUpdate? {
        strategies.first { $0.contractId == p.contractId && ![.closed, .disarmed, .failed].contains($0.state) }
    }

    /// Working orders on the position's contract (any client).
    func workingOrders(for p: Position) -> [OrderInfo] {
        orders.filter { $0.contractId == p.contractId && $0.account == p.account && $0.group == .open }
    }

    /// Closes the whole position with a limit order; returns a summary for the UI.
    func closePosition(_ p: Position, limitPrice: Double) async throws(ActionError) -> String {
        guard let session else { throw ActionError("Not connected") }
        do {
            let placed = try await session.closePosition(contractId: p.contractId, expectedQuantity: p.quantity, limitPrice: limitPrice)
            return "Close order #\(placed.orderId) \(placed.status). \(placed.message)"
        } catch {
            throw ActionError(message(error))
        }
    }

    func protectPosition(_ p: Position, takeProfit: Double?, stop: Double?, stopLimit: Double?) async throws(ActionError) -> String {
        guard let session else { throw ActionError("Not connected") }
        do {
            let placed = try await session.protectPosition(contractId: p.contractId, expectedQuantity: p.quantity,
                                                           takeProfit: takeProfit, stop: stop, stopLimit: stopLimit)
            return placed.map { "#\($0.orderId) \($0.status)" }.joined(separator: ", ")
        } catch {
            throw ActionError(message(error))
        }
    }

    func modifyOrder(_ o: OrderInfo, limitPrice: Double?, stopPrice: Double?) async throws(ActionError) -> String {
        guard let session else { throw ActionError("Not connected") }
        do {
            let placed = try await session.modifyOrder(orderId: o.orderId, limitPrice: limitPrice, stopPrice: stopPrice)
            return "Order #\(placed.orderId) updated (\(placed.status))"
        } catch {
            throw ActionError(message(error))
        }
    }

    // MARK: Orders

    /// Places the order; `lastPlacement` (with the returned id) tracks IB's answer.
    func placeOrder(_ request: OrderRequest) -> UUID? {
        guard let session else { return nil }
        let placement = Placement(request: request, state: .sending)
        lastPlacement = placement
        Task {
            let state: Placement.State
            do {
                state = .accepted(try await session.placeOrder(request: request))
            } catch {
                state = .rejected(message(error))
            }
            if lastPlacement?.id == placement.id { lastPlacement?.state = state }
        }
        return placement.id
    }

    /// The order list's entry for an order this connection placed.
    func order(_ placed: PlacedOrder) -> OrderInfo? {
        orders.first { $0.orderId == placed.orderId && $0.clientId == sessionClientId }
    }

    /// Order ids are per client, so only this connection's orders can be cancelled by id.
    func canCancel(_ o: OrderInfo) -> Bool {
        o.group == .open && o.orderId > 0 && o.clientId == sessionClientId && o.status != "PendingCancel"
    }

    func cancelOrder(_ orderId: Int32) async {
        guard let session else { return }
        do {
            try await session.cancelOrder(orderId: orderId)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        lastError = message(error)
    }

    private func message(_ error: Error) -> String {
        if let error = error as? IbkrError {
            switch error {
            case .Api(let message), .Invalid(let message): message
            }
        } else {
            error.localizedDescription
        }
    }
}

/// A failed position action, with a readable message.
struct ActionError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One order from the ticket and IB's answer to it.
struct Placement: Identifiable {
    enum State {
        case sending
        case accepted(PlacedOrder)
        case rejected(String)
    }

    let id = UUID()
    let request: OrderRequest
    var state: State
}

struct Toast: Identifiable {
    enum Tone { case success, info, warning, failure }

    let id = UUID()
    let title: String
    let detail: String
    let tone: Tone
}

nonisolated extension Position: @retroactive Identifiable {
    public var id: String { "\(account)-\(contractId)" }

    var displaySymbol: String { secType == "STK" || localSymbol.isEmpty ? symbol : localSymbol }
    /// IB's average cost includes the multiplier; this is the per-share / per-premium price.
    var averagePrice: Double { averageCost / max(multiplier, 1) }
}

nonisolated extension OrderInfo: @retroactive Identifiable {
    /// Perm id is unique account-wide; completed orders placed outside the API have order id 0 or -1.
    public var id: String { permId != 0 ? "p\(permId)" : "o\(clientId)-\(orderId)" }

    /// Options share a symbol; use IB's full contract name for them.
    var displaySymbol: String { secType == "STK" || localSymbol.isEmpty ? symbol : localSymbol }
    var isBuy: Bool { action == "Buy" }
}

// MARK: - Listener sinks (called on Rust threads)

/// Delivers on the main queue, which keeps updates in order (unlike unstructured Tasks).
private nonisolated func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

private nonisolated final class PositionsSink: PositionsListener {
    let update: @MainActor @Sendable ([Position]) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable ([Position]) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onPositions(positions: [Position]) { onMain { self.update(positions) } }
    func onError(message: String) { onMain { self.fail(message) } }
}

private nonisolated final class QuoteSink: QuoteListener {
    let update: @MainActor @Sendable (Quote) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable (Quote) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onQuote(quote: Quote) { onMain { self.update(quote) } }
    func onError(message: String) { onMain { self.fail(message) } }
}

private nonisolated final class StrategySink: StrategyListener {
    let update: @MainActor @Sendable (StrategyUpdate) -> Void

    init(update: @escaping @MainActor @Sendable (StrategyUpdate) -> Void) {
        self.update = update
    }

    func onUpdate(update: StrategyUpdate) { onMain { self.update(update) } }
}

private nonisolated final class ConnectionSink: ConnectionListener {
    let update: @MainActor @Sendable (LinkStatus, String) -> Void

    init(update: @escaping @MainActor @Sendable (LinkStatus, String) -> Void) {
        self.update = update
    }

    func onLink(status: LinkStatus, message: String) { onMain { self.update(status, message) } }
}

private nonisolated final class OrdersSink: OrdersListener {
    let update: @MainActor @Sendable ([OrderInfo]) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable ([OrderInfo]) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onOrders(orders: [OrderInfo]) { onMain { self.update(orders) } }
    func onError(message: String) { onMain { self.fail(message) } }
}
