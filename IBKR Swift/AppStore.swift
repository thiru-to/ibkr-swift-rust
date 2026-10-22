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

    private(set) var summary: AccountSummary?
    private(set) var positions: [Position] = []
    private(set) var quote: Quote?
    private(set) var orders: [OpenOrder] = []
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

    @ObservationIgnored private var session: IbkrSession?
    @ObservationIgnored private var streams: [String: StreamHandle] = [:]

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
        summary = nil
        positions = []
        quote = nil
        orders = []
        chain = nil
        underlyingQuote = nil
        optionQuote = nil
        strategyHandles.removeAll()
        strategyUpdates.removeAll()
        strategySpecs.removeAll()
    }

    private func startStreams(_ session: IbkrSession) {
        streams["positions"] = session.subscribePositions(listener: PositionsSink(
            update: { [weak self] in self?.positions = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
        streams["orders"] = session.subscribeOrders(listener: OrdersSink(
            update: { [weak self] in self?.orders = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
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
        streams["quote"] = session.subscribeQuote(symbol: symbol, listener: QuoteSink(
            update: { [weak self] in self?.quote = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
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
        streams["underlying"] = session.subscribeQuote(symbol: symbol, listener: QuoteSink(
            update: { [weak self] in self?.underlyingQuote = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
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

    // MARK: Orders

    /// Returns the new order id, or nil on failure (error is in `lastError`).
    func placeOrder(_ request: OrderRequest) async -> Int32? {
        guard let session else { return nil }
        do {
            return try await session.placeOrder(request: request)
        } catch {
            report(error)
            return nil
        }
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
        if let error = error as? IbkrError {
            switch error {
            case .Api(let message), .Invalid(let message):
                lastError = message
            }
        } else {
            lastError = error.localizedDescription
        }
    }
}

nonisolated extension Position: @retroactive Identifiable {
    public var id: String { "\(account)-\(contractId)" }
}

nonisolated extension OpenOrder: @retroactive Identifiable {
    public var id: Int32 { orderId }
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

private nonisolated final class OrdersSink: OrdersListener {
    let update: @MainActor @Sendable ([OpenOrder]) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable ([OpenOrder]) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onOrders(orders: [OpenOrder]) { onMain { self.update(orders) } }
    func onError(message: String) { onMain { self.fail(message) } }
}
