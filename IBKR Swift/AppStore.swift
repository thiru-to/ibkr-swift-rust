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

    // Connection settings. 4001 = Gateway live, 4002 = Gateway paper.
    var host = "127.0.0.1"
    var port = 4001
    var clientId = 1

    private(set) var connection = Connection.disconnected
    private(set) var account = ""
    private(set) var isLive = false

    private(set) var summary: AccountSummary?
    private(set) var positions: [Position] = []
    private(set) var quote: Quote?
    private(set) var orders: [OpenOrder] = []
    var lastError: String?

    @ObservationIgnored private var session: IbkrSession?
    @ObservationIgnored private var streams: [String: StreamHandle] = [:]

    // MARK: Connection

    func connect() async {
        guard connection == .disconnected, let port = UInt16(exactly: port) else { return }
        connection = .connecting
        lastError = nil
        do {
            let session = try await IbkrCore.connect(host: host, port: port, clientId: Int32(clientId))
            self.session = session
            account = session.account()
            isLive = session.isLive()
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
