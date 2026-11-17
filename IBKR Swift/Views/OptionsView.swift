//
//  OptionsView.swift
//  IBKR Swift
//
//  Option strategy ticket: contract (chain picker) + trigger on the underlying +
//  take-profit / stop-loss / end-of-day exits. Arming always goes through a
//  confirmation that shows LIVE/PAPER; keep it that way.
//

import IbkrCore
import SwiftUI

struct OptionsView: View {
    /// The ticket's current selections, for the P/L simulator.
    @State private var simulation: SimulationInput?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Strategy builder", icon: "scope", tint: .purple)
                    .padding(.horizontal, 20).padding(.top, 20)
                StrategyTicketView(simulation: $simulation)
            }
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 380, minHeight: 0, maxHeight: .infinity)
            VStack(spacing: 0) {
                PnLSimulatorView(input: simulation)
                    .frame(minHeight: 300, maxHeight: 480)
                Divider()
                StrategiesView()
                    .frame(minHeight: 120)
            }
            // Pin every bound. A split-view pane whose minimum size follows its content
            // (live quotes, hover text) makes AppKit re-run layout mid-layout and abort the
            // app; a nested VSplitView here did exactly that.
            .frame(minWidth: 520, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationTitle("Options")
    }
}

/// US/Eastern helpers for expiries ("YYYYMMDD") and DTE.
enum Eastern {
    static let timeZone = TimeZone(identifier: "America/New_York")!

    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static let label: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d"
        return f
    }()

    static var today: String { ymd.string(from: .now) }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `ymd` ("YYYYMMDD") at a time of day, Eastern.
    static func date(_ ymd: String, hour: Int, minute: Int) -> Date? {
        self.ymd.date(from: ymd).flatMap { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: $0) }
    }

    /// Today at "HH:MM" Eastern.
    static func today(at hhmm: String) -> Date? {
        let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return date(today, hour: parts[0], minute: parts[1])
    }

    /// "Thu Oct 23 3:50 PM ET".
    static func timeLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day().hour().minute()) + " ET"
    }

    static func dte(_ expiry: String) -> Int? {
        guard let date = ymd.date(from: expiry), let today = ymd.date(from: today) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.day], from: today, to: date).day
    }

    static func expiryLabel(_ expiry: String) -> String {
        guard let date = ymd.date(from: expiry), let dte = dte(expiry) else { return expiry }
        return dte == 0 ? "Today · 0DTE" : "\(label.string(from: date)) · \(dte)DTE"
    }
}

private enum TriggerMode: String, CaseIterable {
    case immediately = "Immediately"
    case risesTo = "Rises to ≥"
    case fallsTo = "Falls to ≤"
}

private enum TargetMode: String, CaseIterable {
    case off = "Off"
    case percent = "%"
    case dollars = "$"
}

struct StrategyTicketView: View {
    @Environment(AppStore.self) private var store
    /// Published for the P/L simulator next to the ticket.
    @Binding var simulation: SimulationInput?

    @State private var underlying = "SPY"
    @State private var expiry: String?
    @State private var right = OptionRight.call
    @State private var strike: Double?
    @State private var quantity = 1

    @State private var triggerMode = TriggerMode.risesTo
    @State private var triggerPrice: Double?

    @State private var tpMode = TargetMode.percent
    @State private var tpValue: Double? = 50
    @State private var slMode = TargetMode.percent
    @State private var slValue: Double? = 30
    @State private var stopLimit = false
    @State private var limitOffset: Double? = 0.05

    @State private var closeAtEnabled = true
    @State private var closeAt = "15:50"
    @State private var allowDelayed = false

    @State private var confirming = false

    // Quick Buy: preset immediate market buy of ATM contracts on the nearest expiry.
    @AppStorage(QuickBuyKeys.symbol) private var quickSymbol = "SPY"
    @AppStorage(QuickBuyKeys.quantity) private var quickQuantity = 10
    @AppStorage(QuickBuyKeys.callShortcut) private var callShortcut = ""
    @AppStorage(QuickBuyKeys.putShortcut) private var putShortcut = ""
    /// LIVE only; paper buys straight away.
    @State private var quickConfirm: QuickBuyRequest?
    /// Blocks re-presses (double-clicks, held shortcut keys) for a moment.
    @State private var quickBusy = false

    private var underlyingLast: Double? { store.underlyingQuote?.last }

    private var optionSpec: OptionSpec? {
        guard let chain = store.chain, let expiry, let strike else { return nil }
        return OptionSpec(symbol: chain.symbol, expiry: expiry, right: right, strike: strike)
    }

    /// Strikes around the reference price (trigger, else last), so the picker stays short.
    private var nearbyStrikes: [Double] {
        guard let strikes = store.chain?.strikes, !strikes.isEmpty else { return [] }
        let reference = referencePrice ?? strikes[strikes.count / 2]
        let center = strikes.indices.min { abs(strikes[$0] - reference) < abs(strikes[$1] - reference) } ?? 0
        let range = max(0, center - 25)...min(strikes.count - 1, center + 25)
        var nearby = Array(strikes[range])
        if let strike, !nearby.contains(strike) { nearby.append(strike); nearby.sort() }
        return nearby
    }

    private var referencePrice: Double? {
        triggerMode == .immediately ? underlyingLast : (triggerPrice ?? underlyingLast)
    }

    private func target(_ mode: TargetMode, _ value: Double?) -> Target? {
        switch mode {
        case .off: nil
        case .percent: value.map { .percent(value: $0) }
        case .dollars: value.map { .dollars(value: $0) }
        }
    }

    /// The ticket's exits; nil when a value is invalid. Shared with Quick Buy.
    private var exits: (takeProfit: Target?, stopLoss: StopSpec?, eodClose: String?)? {
        if tpMode != .off && (tpValue ?? 0) <= 0 { return nil }
        if slMode != .off && (slValue ?? 0) <= 0 { return nil }
        let stopLoss = target(slMode, slValue).map {
            StopSpec(target: $0, kind: stopLimit ? .stopLimit(limitOffset: limitOffset ?? 0) : .stopMarket)
        }
        return (target(tpMode, tpValue), stopLoss, closeAtEnabled ? closeAt.trimmingCharacters(in: .whitespaces) : nil)
    }

    private var spec: StrategySpec? {
        guard let option = optionSpec, quantity > 0, let exits else { return nil }
        var trigger: Trigger?
        if triggerMode != .immediately {
            guard let triggerPrice, triggerPrice > 0 else { return nil }
            trigger = Trigger(underlying: option.symbol,
                              direction: triggerMode == .risesTo ? .risesTo : .fallsTo,
                              price: triggerPrice)
        }
        return StrategySpec(
            option: option,
            quantity: Double(quantity),
            trigger: trigger,
            takeProfit: exits.takeProfit,
            stopLoss: exits.stopLoss,
            eodClose: exits.eodClose,
            allowDelayed: !store.isLive && allowDelayed
        )
    }

    // MARK: Quick Buy

    private var quickSymbolNormalized: String { quickSymbol.trimmingCharacters(in: .whitespaces).uppercased() }

    /// The loaded chain is the preset's underlying.
    private var quickChainReady: Bool { store.chain?.symbol.uppercased() == quickSymbolNormalized }

    /// Strike nearest the underlying's last price.
    private var quickStrike: Double? {
        guard quickChainReady, let strikes = store.chain?.strikes, let last = underlyingLast else { return nil }
        return strikes.min { abs($0 - last) < abs($1 - last) }
    }

    private var quickExpiry: String? { quickChainReady ? store.chain?.expirations.first : nil }

    /// Immediate market buy of `quickQuantity` ATM contracts on the nearest expiry, with the ticket's exits.
    private func quickSpec(_ right: OptionRight) -> StrategySpec? {
        guard let chain = store.chain, let expiry = quickExpiry, let strike = quickStrike,
              quickQuantity > 0, let exits else { return nil }
        return StrategySpec(
            option: OptionSpec(symbol: chain.symbol, expiry: expiry, right: right, strike: strike),
            quantity: Double(quickQuantity),
            trigger: nil,
            takeProfit: exits.takeProfit,
            stopLoss: exits.stopLoss,
            eodClose: exits.eodClose,
            allowDelayed: false
        )
    }

    /// Cost is checked by the Rust side at the ask when the entry is sent.
    private var quickRiskProblem: String? { store.entryProblem(cost: nil, requirePrice: false) }

    private var quickDisabled: Bool {
        quickBusy || quickRiskProblem != nil || quickSpec(.call) == nil || store.connection != .connected
    }

    private func quickBuy(_ right: OptionRight) {
        guard !quickBusy, quickRiskProblem == nil, let spec = quickSpec(right) else { return }
        quickBusy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            quickBusy = false
        }
        if store.isLive {
            quickConfirm = QuickBuyRequest(spec: spec)
        } else {
            sendQuick(spec)
        }
    }

    private func sendQuick(_ spec: StrategySpec) {
        store.arm(spec)
        store.post(Toast(title: "Quick Buy sent", detail: "BUY \(contractLabel(spec)) at market", tone: .info))
    }

    private func contractLabel(_ s: StrategySpec) -> String {
        let o = s.option
        let dte = Eastern.dte(o.expiry).map { "\($0)DTE" } ?? o.expiry
        return "\(Int(s.quantity)) \(o.symbol) \(dte) \(o.strike.formatted())\(o.right == .call ? "C" : "P")"
    }

    @ViewBuilder
    private var quickBuySection: some View {
        Section {
            if quickChainReady {
                HStack {
                    quickButton(.call, shortcut: callShortcut)
                    quickButton(.put, shortcut: putShortcut)
                }
                .controlSize(.large)
                Group {
                    if let strike = quickStrike, let expiry = quickExpiry {
                        Text("\(quickSymbolNormalized) \(Eastern.expiryLabel(expiry)) · \(strike.formatted()) strike · market · exits from the ticket below")
                    } else {
                        Text("Waiting for \(quickSymbolNormalized)'s last price…")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if exits == nil {
                    Text("Fix the ticket's exit values first.").font(.caption).foregroundStyle(.red)
                }
            } else {
                Button("Load \(quickSymbolNormalized)") {
                    underlying = quickSymbolNormalized
                    Task { await loadChain() }
                }
                .disabled(store.loadingChain || quickSymbolNormalized.isEmpty)
                .frame(maxWidth: .infinity)
            }
            if let quickRiskProblem {
                Label(quickRiskProblem, systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Quick Buy")
                Spacer()
                SettingsLink { Text("Presets & Shortcuts…") }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func quickButton(_ right: OptionRight, shortcut raw: String) -> some View {
        let shortcut = Shortcut.decode(raw)
        let title = "Buy \(quickQuantity) ATM \(right == .call ? "Call" : "Put")"
        return Button {
            quickBuy(right)
        } label: {
            VStack(spacing: 2) {
                Text(title).bold()
                if let shortcut { Text(shortcut.display).font(.caption2).opacity(0.8) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(right == .call ? .green : .red)
        .disabled(quickDisabled)
        .quickBuyShortcut(shortcut)
    }

    private var simulationInput: SimulationInput? {
        guard let option = optionSpec, quantity > 0 else { return nil }
        return SimulationInput(
            option: option,
            quantity: Double(quantity),
            multiplier: store.chain?.multiplier ?? 100,
            triggerPrice: triggerMode == .immediately ? nil : triggerPrice.flatMap { $0 > 0 ? $0 : nil },
            takeProfit: target(tpMode, tpValue),
            stopLoss: target(slMode, slValue),
            closeAt: closeAtEnabled ? closeAt : nil
        )
    }

    /// The Rust side enforces this too; checking here gives immediate feedback.
    private var triggerProblem: String? {
        guard triggerMode != .immediately, let price = triggerPrice, let last = underlyingLast else { return nil }
        if triggerMode == .risesTo && last >= price { return "\(underlying) is already at \(last.formatted()) — above the trigger" }
        if triggerMode == .fallsTo && last <= price { return "\(underlying) is already at \(last.formatted()) — below the trigger" }
        return nil
    }

    /// Checked again by the Rust side when the entry is sent, at the ask then.
    private var riskProblem: String? {
        guard let spec else { return nil }
        let cost = store.optionQuote?.ask.map { $0 * spec.quantity * (store.chain?.multiplier ?? 100) }
        return store.entryProblem(cost: cost)
    }

    var body: some View {
        Form {
            quickBuySection

            Section("Contract") {
                HStack {
                    TextField("Underlying", text: $underlying)
                        .onSubmit { Task { await loadChain() } }
                    Button("Load") { Task { await loadChain() } }
                        .disabled(store.loadingChain)
                }
                if let q = store.underlyingQuote {
                    LabeledContent("\(q.symbol) last") {
                        HStack {
                            Text(q.last.formatted()).monospacedDigit()
                            if q.delayed { Text("DELAYED").font(.caption.bold()).foregroundStyle(.orange) }
                        }
                    }
                }
                if let chain = store.chain {
                    Picker("Expiry", selection: $expiry) {
                        ForEach(chain.expirations.prefix(30), id: \.self) { e in
                            Text(Eastern.expiryLabel(e)).tag(Optional(e))
                        }
                    }
                    Picker("Right", selection: $right) {
                        Text("Call").tag(OptionRight.call)
                        Text("Put").tag(OptionRight.put)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Picker("Strike", selection: $strike) {
                            ForEach(nearbyStrikes, id: \.self) { s in
                                Text(s.formatted(.number.precision(.fractionLength(0...2)))).tag(Optional(s))
                            }
                        }
                        Button("ATM") { snapStrike() }
                            .help("Strike nearest the trigger price (or the last price)")
                    }
                    Stepper("Contracts: \(quantity)", value: $quantity, in: 1...500)
                    if let oq = store.optionQuote {
                        LabeledContent(oq.symbol) {
                            Text("\(oq.bid.formatted()) × \(oq.ask.formatted())\(oq.delayed ? " (delayed)" : "")")
                                .monospacedDigit()
                        }
                    }
                } else if store.loadingChain {
                    ProgressView().controlSize(.small)
                }
            }

            Section("Entry trigger (market buy)") {
                Picker("When \(underlying.uppercased())", selection: $triggerMode) {
                    ForEach(TriggerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if triggerMode != .immediately {
                    TextField("Trigger price", value: $triggerPrice, format: .number.precision(.fractionLength(0...2)))
                    if let triggerProblem {
                        Text(triggerProblem).font(.caption).foregroundStyle(.red)
                    }
                }
                if !store.isLive {
                    Toggle("Allow delayed data (paper testing)", isOn: $allowDelayed)
                        .help("Paper accounts often get delayed quotes; live accounts never fire on delayed data.")
                }
            }

            Section("Exits (placed when the entry fills)") {
                targetRow("Take profit", mode: $tpMode, value: $tpValue)
                targetRow("Stop loss", mode: $slMode, value: $slValue)
                if slMode != .off {
                    Picker("Stop type", selection: $stopLimit) {
                        Text("Stop-market").tag(false)
                        Text("Stop-limit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if stopLimit {
                        TextField("Limit below stop", value: $limitOffset, format: .number.precision(.fractionLength(0...2)))
                    }
                }
                Toggle("Close at (ET)", isOn: $closeAtEnabled)
                if closeAtEnabled {
                    TextField("HH:MM", text: $closeAt)
                }
            }

            Section {
                if let riskProblem {
                    Label(riskProblem, systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.red)
                }
                Button(triggerMode == .immediately ? "Review Buy…" : "Review & Arm…") { confirming = true }
                    .disabled(spec == nil || triggerProblem != nil || riskProblem != nil)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .task { if store.chain == nil { await loadChain() } }
        .onChange(of: optionSpec) { store.watchOption(optionSpec) }
        .onChange(of: simulationInput, initial: true) { simulation = simulationInput }
        .onChange(of: expiry) { closeAtEnabled = expiry.map { Eastern.dte($0) == 0 } ?? true }
        .confirmationDialog(confirmTitle, isPresented: $confirming, presenting: spec) { spec in
            Button(store.isLive ? "Arm LIVE Strategy" : "Arm Paper Strategy", role: store.isLive ? .destructive : nil) {
                store.arm(spec)
            }
            Button("Cancel", role: .cancel) {}
        } message: { spec in
            Text(summary(spec))
        }
        .sheet(item: $quickConfirm) { request in
            QuickBuyConfirmSheet(summary: summary(request.spec)) { sendQuick(request.spec) }
        }
    }

    private var confirmTitle: String {
        triggerMode == .immediately ? "Buy now?" : "Arm strategy?"
    }

    private func targetRow(_ label: String, mode: Binding<TargetMode>, value: Binding<Double?>) -> some View {
        HStack {
            Picker(label, selection: mode) {
                ForEach(TargetMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if mode.wrappedValue != .off {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 70)
            }
        }
    }

    private func loadChain() async {
        await store.loadChain(symbol: underlying)
        guard let chain = store.chain else { return }
        if expiry == nil || !chain.expirations.contains(expiry!) {
            expiry = chain.expirations.first
        }
        // Wait briefly for a first price so ATM is meaningful.
        for _ in 0..<20 where underlyingLast == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        snapStrike()
    }

    private func snapStrike() {
        guard let strikes = store.chain?.strikes, let reference = referencePrice else { return }
        strike = strikes.min { abs($0 - reference) < abs($1 - reference) }
    }

    private func summary(_ s: StrategySpec) -> String {
        let o = s.option
        let mult = store.chain?.multiplier ?? 100
        var lines = ["BUY \(Int(s.quantity)) \(o.symbol) \(Eastern.expiryLabel(o.expiry)) \(o.strike.formatted()) \(o.right == .call ? "CALL" : "PUT") at market"]
        if let t = s.trigger {
            let now = underlyingLast.map { " (now \($0.formatted()))" } ?? ""
            lines.append("When \(t.underlying) \(t.direction == .risesTo ? "rises to ≥" : "falls to ≤") \(t.price.formatted())\(now)")
        } else {
            lines.append("Immediately")
        }
        let tp = s.takeProfit.map { describe($0, sign: "+") } ?? "none"
        let sl = s.stopLoss.map { sl in
            let kind = switch sl.kind {
            case .stopMarket: "stop-market"
            case .stopLimit(let offset): "stop-limit −\(offset.formatted())"
            }
            return "\(describe(sl.target, sign: "−")) (\(kind))"
        } ?? "none"
        lines.append("Take profit \(tp) · Stop \(sl)")
        if let eod = s.eodClose { lines.append("Close at \(eod) ET") }
        // `optionQuote` is the ticket's contract; a Quick Buy may be a different one.
        if s.option == optionSpec, let q = store.optionQuote, let ask = q.ask {
            let mid = q.bid.map { ($0 + ask) / 2 } ?? ask
            lines.append("Est. cost \((ask * s.quantity * mult).formatted(.currency(code: "USD"))) (ask \(ask.formatted()))\(q.delayed ? " — delayed quote" : "")")
            lines.append("Exits are priced from the actual fill (now ≈ \(mid.formatted()))")
        } else {
            lines.append("Cost is checked against your limits at the ask when sent")
            lines.append("Exits are priced from the actual fill")
        }
        if s.allowDelayed { lines.append("⚠︎ Trigger may fire on DELAYED data") }
        lines.append("")
        lines.append("Account \(store.account) — \(store.isLive ? "LIVE (real money)" : "PAPER")")
        if s.trigger != nil { lines.append("Keep the app open and connected until it triggers.") }
        return lines.joined(separator: "\n")
    }

    private func describe(_ t: Target, sign: String) -> String {
        switch t {
        case .percent(let v): "\(sign)\(v.formatted())%"
        case .dollars(let v): "\(sign)\(v.formatted(.currency(code: "USD")))"
        }
    }
}
