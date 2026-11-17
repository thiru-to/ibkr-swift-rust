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

    // Connection settings, remembered across launches.
    var host: String { didSet { defaults.set(host, forKey: "host") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var clientId: Int { didSet { defaults.set(clientId, forKey: "clientId") } }

    /// Connect at launch and keep retrying until Gateway answers. An explicit Disconnect
    /// stops it until the next launch (or until it's switched off and on again).
    var autoConnect: Bool {
        didSet {
            defaults.set(autoConnect, forKey: "autoConnect")
            if autoConnect { startAutoConnect() } else { stopAutoConnect() }
        }
    }
    /// While auto-connect waits for Gateway: when it tries next, and why the last try failed.
    private(set) var nextAttempt: Date?
    private(set) var lastAttemptError: String?
    @ObservationIgnored private var autoConnectTask: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard

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
    private(set) var quoteInstrument: Instrument?
    private(set) var historyError: String?
    private(set) var quoteTradeBusy = false
    private(set) var quoteTradeStatus: String?
    private(set) var quoteTradeLocked = false
    @ObservationIgnored private var quoteGeneration = UUID()
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
    /// The risk guard's limits, halt and daily P&L; nil until it starts.
    private(set) var risk: RiskStatus?
    /// Realized P&L tallies (Day / Week / Month / Year) for the Orders screen.
    private(set) var ledger: LedgerSnapshot?

    // Options
    private(set) var chain: OptionChain?
    private(set) var loadingChain = false
    private(set) var underlyingQuote: Quote?
    private(set) var optionQuote: Quote?
    private(set) var strategyUpdates: [UInt64: StrategyUpdate] = [:]
    /// What was armed, for display (the Rust side only reports progress).
    private(set) var strategySpecs: [UInt64: StrategySpec] = [:]
    @ObservationIgnored private var strategyHandles: [UInt64: StrategyHandle] = [:]

    /// IB's live P&L for positions that running strategies hold, by contract id.
    private(set) var positionPnl: [Int32: PositionPnl] = [:]
    /// Fill timing of finished strategy entries, oldest first (this account's log).
    private(set) var latencyLog: [OrderTiming] = []

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
    @ObservationIgnored private var historyKey: (instrument: Instrument, range: ChartRange, interval: BarInterval)?
    @ObservationIgnored private var historyLoadedAt: ContinuousClock.Instant?
    /// IB had nothing older (or failed); stop paging until the next fresh load.
    @ObservationIgnored private var historyExhausted = false
    @ObservationIgnored private var lastOlderHistory: ContinuousClock.Instant?
    @ObservationIgnored private var chartLevelsCache: [String: (Date, ChartSessionLevels)] = [:]
    /// Group and fill per order id from the previous snapshot; nil until the first one,
    /// which is the baseline (no toasts for orders that were already done).
    @ObservationIgnored private var orderMemory: [String: (group: OrderStatusGroup, filled: Double)]?

    init() {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "tradingMode").flatMap(TradingMode.init) ?? .paper
        self.mode = mode
        host = defaults.string(forKey: "host") ?? "127.0.0.1"
        port = defaults.object(forKey: "port") as? Int ?? mode.defaultPort
        clientId = defaults.object(forKey: "clientId") as? Int ?? 1
        autoConnect = defaults.object(forKey: "autoConnect") as? Bool ?? true
    }

    // MARK: Connection

    /// Starts auto-connect if it's on and nothing is connected. Retries back off from
    /// 2s to 30s, so a Gateway that isn't running yet isn't hammered.
    func startAutoConnect() {
        guard autoConnect, autoConnectTask == nil, connection == .disconnected else { return }
        autoConnectTask = Task { [weak self] in
            var delay = Duration.seconds(2)
            while let self, self.autoConnect, !Task.isCancelled, self.connection == .disconnected {
                await self.connect(quietly: true)
                guard self.connection == .disconnected else { break }
                self.nextAttempt = .now + TimeInterval(delay.components.seconds)
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
            self?.nextAttempt = nil
            self?.autoConnectTask = nil
        }
    }

    private func stopAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
        nextAttempt = nil
        lastAttemptError = nil
    }

    /// `quietly`: failures go to `lastAttemptError` (shown while waiting) instead of the
    /// error banner, so auto-connect retries don't flash errors.
    func connect(quietly: Bool = false) async {
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
            lastAttemptError = nil
            startStreams(session)
            await refreshSummary()
        } catch {
            connection = .disconnected
            if quietly { lastAttemptError = message(error) } else { report(error) }
        }
    }

    func disconnect() async {
        stopAutoConnect()
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
        quoteGeneration = UUID()
        quoteInstrument = nil
        quote = nil
        historyRequest += 1
        historyKey = nil
        historyLoadedAt = nil
        loadingHistory = false
        loadingOlderHistory = false
        historyError = nil
        history = []
        chartLevelsCache.removeAll()
        ticketQuote = nil
        positionQuote = nil
        watched.removeAll()
        watchedOption = nil
        watchedContract = nil
        orders = []
        orderMemory = nil
        risk = nil
        ledger = nil
        lastPlacement = nil
        chain = nil
        underlyingQuote = nil
        optionQuote = nil
        strategyHandles.removeAll()
        strategyUpdates.removeAll()
        strategySpecs.removeAll()
        positionPnl.removeAll()
        latencyLog = []
    }

    private func startStreams(_ session: IbkrSession) {
        streams["link"] = session.subscribeConnection(listener: ConnectionSink { [weak self] in
            self?.linkChanged($0, $1)
        })
        streams["positions"] = session.subscribePositions(listener: PositionsSink(
            update: { [weak self] in self?.positions = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
        streams["risk"] = session.startRisk(statePath: Self.riskStatePath(account: account), listener: RiskSink(
            update: { [weak self] in self?.riskChanged($0) },
            fail: { [weak self] in self?.lastError = $0 }
        ))
        let latencyPath = Self.latencyPath(account: account)
        // Reading and decoding an account's accumulated log must not stall the first frame.
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) {
                session.openLatencyLog(path: latencyPath)
            }.value
            guard let self, self.session === session else { return }
            let savedIDs = Set(saved.map(\.id))
            self.latencyLog = saved + self.latencyLog.filter { !savedIDs.contains($0.id) }
        }
        streams["ledger"] = session.subscribeLedger(statePath: Self.ledgerPath(account: account), listener: LedgerSink(
            update: { [weak self] in self?.ledger = $0 },
            fail: { [weak self] in self?.lastError = $0 }
        ))
        refreshOrders()
    }

    /// Fill timing of strategy entries, one JSON object per line, per account.
    private static func latencyPath(account: String) -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "Latency/\(account).jsonl").path(percentEncoded: false)
    }

    /// Fills and commissions, per account, so Month / Year tallies outlive IB's 7-day window.
    private static func ledgerPath(account: String) -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "Ledger/\(account).json").path(percentEncoded: false)
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
            historyLoadedAt = nil
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
        if let quoteInstrument { subscribeQuoteInstrument(quoteInstrument) }
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

    // MARK: Risk

    /// Saved per account, so a halt survives restarts and paper and live keep separate limits.
    private static func riskStatePath(account: String) -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appending(path: "Risk/\(account).json").path(percentEncoded: false)
    }

    private func riskChanged(_ status: RiskStatus) {
        // The guard reports once more as it stops; ignore that after disconnecting.
        guard connection == .connected else { return }
        if risk?.halted == nil, let reason = status.halted {
            post(Toast(title: "Trading halted", detail: "\(reason). New entries are blocked for today; exits still work.", tone: .failure))
        }
        risk = status
    }

    /// Tighter limits apply now; looser ones from the next trading day.
    func setRiskLimits(_ limits: RiskLimits) throws(ActionError) {
        guard let session else { throw ActionError("Not connected") }
        do {
            risk = try session.setRiskLimits(limits: limits)
        } catch {
            throw ActionError(message(error))
        }
    }

    /// Kill switch for the rest of the trading day. Strategies that haven't bought are
    /// disarmed, entries in flight and this connection's buy orders are cancelled.
    func haltTrading() {
        session?.haltTrading(reason: "Halted manually")
    }

    /// Why the guard would refuse an opening order costing `cost` (nil = unknown). The
    /// Rust side checks again right before sending; this is for immediate feedback.
    /// With `requirePrice` false, an unknown cost isn't a problem here (the Rust side
    /// snapshots the ask and checks it before sending).
    func entryProblem(cost: Double?, requirePrice: Bool = true) -> String? {
        guard let risk else { return isLive ? "Risk controls aren't running yet." : nil }
        if let reason = risk.halted { return "Trading is halted for today (\(reason))." }
        if isLive && !risk.running { return "Risk controls aren't running, so opening orders are refused on live accounts." }
        if let max = risk.limits.maxDailyLoss {
            guard let pnl = risk.dailyPnl else { return "Waiting for IB's daily P&L." }
            if pnl <= -max { return "Daily loss limit reached." }
        }
        if let max = risk.limits.maxCostPerTrade {
            guard let cost else {
                return requirePrice ? "No price yet to check against the max cost per trade (\(Optional(max).money("USD")))." : nil
            }
            if cost > max { return "Est. cost \(Optional(cost).money("USD")) is above the max cost per trade (\(Optional(max).money("USD")))." }
        }
        return nil
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
            let summary = try await session.accountSummary()
            guard self.session === session else { return }
            self.summary = summary
        } catch {
            guard self.session === session else { return }
            report(error)
        }
    }

    func searchInstruments(_ query: String) async throws -> InstrumentSearchResults {
        guard let session else { throw ActionError( "Connect to IB Gateway to search.") }
        do { return try await session.searchInstruments(query: query) }
        catch { throw ActionError( message(error)) }
    }

    func searchChains(_ underlying: Instrument) async throws -> [SearchChain] {
        guard let session else { throw ActionError( "Gateway disconnected.") }
        do { return try await session.searchOptionChains(underlying: underlying) }
        catch { throw ActionError( message(error)) }
    }

    func searchContracts(_ underlying: Instrument, chain: SearchChain, expiry: String, call: Bool) async throws -> [Instrument] {
        guard let session else { throw ActionError( "Gateway disconnected.") }
        do { return try await session.searchOptionContracts(underlying: underlying, chain: chain, expiry: expiry, call: call) }
        catch { throw ActionError( message(error)) }
    }

    func watchInstrument(_ instrument: Instrument) {
        guard session != nil else { return }
        quoteInstrument = instrument
        historyRequest += 1
        historyKey = nil
        historyLoadedAt = nil
        history = []
        historyError = nil
        historySeries += 1
        loadingHistory = false
        loadingOlderHistory = false
        lastOlderHistory = nil
        quote = Quote(symbol: instrument.localSymbol.isEmpty ? instrument.symbol : instrument.localSymbol,
                      bid: nil, ask: nil, last: nil, close: nil, bidSize: nil, askSize: nil, volume: nil, delayed: false)
        subscribeQuoteInstrument(instrument)
    }

    private func subscribeQuoteInstrument(_ instrument: Instrument) {
        guard let session else { return }
        streams["quote"]?.cancel()
        quoteGeneration = UUID()
        let generation = quoteGeneration
        streams["quote"] = session.subscribeInstrumentQuote(instrument: instrument, listener: QuoteSink(
            update: { [weak self] q in
                guard self?.quoteGeneration == generation else { return }
                self?.quote = q
            }, fail: { [weak self] error in
                guard self?.quoteGeneration == generation else { return }
                self?.lastError = error
            }))
    }

    func loadHistory(instrument: Instrument, range: ChartRange, interval: BarInterval) async {
        guard let session else { return }
        // A quick trip to another screen should not blank the chart or repeat an IB request.
        if let key = historyKey, key.instrument == instrument, key.range == range, key.interval == interval,
           let loaded = historyLoadedAt, ContinuousClock.now - loaded < .seconds(60), !history.isEmpty {
            return
        }
        historyRequest += 1
        let request = historyRequest
        historyKey = (instrument, range, interval)
        historyLoadedAt = nil
        historyExhausted = false
        loadingOlderHistory = false
        historyError = nil
        loadingHistory = true
        history = []
        defer {
            if request == historyRequest {
                historySeries += 1
                loadingHistory = false
            }
        }
        do {
            let bars = try await session.instrumentHistory(instrument: instrument, range: range, interval: interval, end: nil)
            guard request == historyRequest else { return }
            guard !Task.isCancelled else { return }
            history = bars
            historyLoadedAt = .now
            if bars.isEmpty { historyError = "No historical data available for this instrument." }
        } catch {
            guard request == historyRequest else { return }
            guard !Task.isCancelled else { return }
            historyError = message(error)
        }
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
        defer { if request == historyRequest { loadingOlderHistory = false } }
        do {
            let older = try await session.instrumentHistory(instrument: key.instrument, range: key.range,
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

    /// Reuses session data across indicator toggles and chart interval changes.
    func chartSessionLevels(instrument: Instrument, sessionTime: Int64) async throws -> ChartSessionLevels {
        guard let session else { throw ActionError("Connect to IB Gateway to load indicators.") }
        let key = "\(instrument.contractId)|\(sessionTime)"
        if let (loaded, levels) = chartLevelsCache[key] {
            let historical = sessionTime < ChartSessionClock.startOfDay(.now)
            if Date.now.timeIntervalSince(loaded) < 60 ||
                (historical && levels.intradayError == nil && levels.previousDayError == nil) {
                return levels
            }
        }
        do {
            let levels = try await session.chartSessionLevels(instrument: instrument, sessionTime: sessionTime)
            try Task.checkCancellation()
            guard self.session === session else { throw ActionError("Gateway disconnected.") }
            if chartLevelsCache.count >= 24 { chartLevelsCache.removeAll() }
            chartLevelsCache[key] = (.now, levels)
            return levels
        } catch {
            throw ActionError(message(error))
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
            update: { [weak self] in self?.strategyChanged($0) }
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
        syncPositionPnl()
    }

    private func strategyChanged(_ update: StrategyUpdate) {
        strategyUpdates[update.id] = update
        // The Rust side logged it to disk; mirror it for the history view.
        if let t = update.entryTiming, t.outcome != "Working",
           !latencyLog.contains(where: { $0.orderId == t.orderId && $0.submittedAtMs == t.submittedAtMs }) {
            latencyLog.append(t)
        }
        syncPositionPnl()
    }

    /// Keeps one IB P&L stream per contract that a strategy holds a filled position in.
    private func syncPositionPnl() {
        guard let session else { return }
        let holding: Set<StrategyState> = [.protected, .open, .unprotected, .closing]
        let wanted = Set(strategyUpdates.values
            .filter { $0.contractId != 0 && $0.filledQuantity > 0 && holding.contains($0.state) }
            .map(\.contractId))
        for key in streams.keys where key.hasPrefix("pnl.") {
            guard let id = Int32(key.dropFirst(4)), !wanted.contains(id) else { continue }
            streams[key]?.cancel()
            streams[key] = nil
            positionPnl[id] = nil
        }
        for id in wanted where streams["pnl.\(id)"] == nil {
            streams["pnl.\(id)"] = session.subscribePositionPnl(contractId: id, listener: PositionPnlSink(
                update: { [weak self] p in
                    // Ignore a last reading that lands after the stream was dropped.
                    guard self?.streams["pnl.\(p.contractId)"] != nil else { return }
                    self?.positionPnl[p.contractId] = p
                },
                fail: { [weak self] in self?.lastError = $0 }
            ))
        }
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

    func submitQuoteTrade(_ request: InstrumentOrderRequest, closeQuantity: Double?, closing: Bool, reviewedAccount: String, reviewedLive: Bool) async {
        guard let session, connection == .connected, linkProblem == nil,
              !quoteTradeBusy, !quoteTradeLocked,
              account == reviewedAccount, isLive == reviewedLive,
              quoteInstrument?.contractId == request.instrument.contractId else { return }
        quoteTradeBusy = true
        quoteTradeLocked = true
        quoteTradeStatus = closing ? "Cancelling working orders and closing…" : "Submitting…"
        Task { try? await Task.sleep(for: .seconds(2)); quoteTradeLocked = false }
        defer { quoteTradeBusy = false }
        do {
            let placed: PlacedOrder
            if closing {
                placed = try await session.closePositionMarket(contractId: request.instrument.contractId, expectedQuantity: reviewedLive ? closeQuantity : nil)
            } else {
                placed = try await session.placeInstrumentOrder(request: request)
            }
            quoteTradeStatus = "\(request.instrument.symbol) · \(placed.orderId > 0 ? "Order #\(placed.orderId): " : "")\(placed.status). \(placed.message)"
            post(Toast(title: closing ? "Close submitted" : "Order submitted", detail: quoteTradeStatus ?? "", tone: .info))
        } catch {
            quoteTradeStatus = message(error)
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

private nonisolated final class RiskSink: RiskListener {
    let update: @MainActor @Sendable (RiskStatus) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable (RiskStatus) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onRisk(status: RiskStatus) { onMain { self.update(status) } }
    func onError(message: String) { onMain { self.fail(message) } }
}

private nonisolated final class PositionPnlSink: PositionPnlListener {
    let update: @MainActor @Sendable (PositionPnl) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable (PositionPnl) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onPnl(pnl: PositionPnl) { onMain { self.update(pnl) } }
    func onError(message: String) { onMain { self.fail(message) } }
}

private nonisolated final class LedgerSink: LedgerListener {
    let update: @MainActor @Sendable (LedgerSnapshot) -> Void
    let fail: @MainActor @Sendable (String) -> Void

    init(update: @escaping @MainActor @Sendable (LedgerSnapshot) -> Void,
         fail: @escaping @MainActor @Sendable (String) -> Void) {
        self.update = update
        self.fail = fail
    }

    func onLedger(snapshot: LedgerSnapshot) { onMain { self.update(snapshot) } }
    func onError(message: String) { onMain { self.fail(message) } }
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
