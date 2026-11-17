import IbkrCore
import SwiftUI

struct InstrumentSearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var query: String
    let select: (Instrument) -> Void
    @State private var results: [Instrument] = []
    @State private var unavailableIndexes: [String] = []
    @State private var filter = "All"
    @State private var selected: Int32?
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    @State private var underlying: Instrument?

    private var visible: [Instrument] {
        results.filter { i in
            switch filter {
            case "Stocks": i.kind == "STK"
            case "ETFs": i.kind == "ETF"
            case "Indexes": i.kind == "IND"
            case "Options": i.hasOptions
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Search instruments").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let underlying {
                OptionContractSearch(underlying: underlying, select: select) { self.underlying = nil }
            } else {
                InstrumentSearchField(text: $query, submit: choose, move: move)
                    .frame(height: 28)
                Picker("Instrument type", selection: $filter) {
                    ForEach(["All", "Stocks", "ETFs", "Indexes", "Options"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                if loading { ProgressView("Searching IB Gateway…").controlSize(.small) }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { retry += 1 }
                }
                List(selection: $selected) {
                    ForEach(visible, id: \.contractId) { i in
                        HStack {
                            Button { if filter == "Options" { underlying = i } else { select(i) } } label: {
                                InstrumentResultRow(instrument: i)
                            }.buttonStyle(.plain)
                            if i.hasOptions && filter != "Options" {
                                Button("Options…") { underlying = i }
                            }
                        }.padding(.vertical, 6).tag(i.contractId)
                    }
                }
                .overlay {
                    if !loading && error == nil && visible.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "Type a ticker or name" : "No matching instruments",
                            systemImage: "magnifyingglass",
                            description: Text("Try a more specific ticker. Unavailable indexes are omitted."))
                    }
                }
                if !unavailableIndexes.isEmpty {
                    Text("Unavailable through Gateway: " + unavailableIndexes.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("US & Canadian listings • IB returns up to 16 stock/ETF matches • Major indexes included")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 680, height: 540)
        .onChange(of: filter) { _, _ in selected = visible.first?.contractId }
        .task(id: "\(query)|\(retry)") {
            results = []; unavailableIndexes = []; selected = nil; error = nil
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { loading = false; return }
            loading = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let found = try await store.searchInstruments(text)
                try Task.checkCancellation()
                results = found.instruments
                unavailableIndexes = found.unavailableIndexes
                selected = visible.first?.contractId
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? ActionError)?.message ?? error.localizedDescription
                loading = false
            }
        }
    }

    private func choose() {
        guard let i = visible.first(where: { $0.contractId == selected }) else { return }
        if filter == "Options" { underlying = i } else { select(i) }
    }
    private func move(_ offset: Int) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex(where: { $0.contractId == selected }) ?? 0
        selected = visible[min(max(index + offset, 0), visible.count - 1)].contractId
    }
}

private struct InstrumentResultRow: View {
    let instrument: Instrument
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(instrument.kind == "OPT" ? instrument.localSymbol : instrument.symbol).font(.headline)
                Text(instrument.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Pill(text: instrument.kind, color: instrument.kind == "OPT" ? .purple : .blue)
            Text("\(instrument.primaryExchange) · \(instrument.currency)").font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
    }
}

private struct OptionContractSearch: View {
    @Environment(AppStore.self) private var store
    let underlying: Instrument
    let select: (Instrument) -> Void
    let back: () -> Void
    @FocusState private var contractsFocused: Bool
    @State private var chains: [SearchChain] = []
    @State private var chainIndex = 0
    @State private var expiry = ""
    @State private var call = true
    @State private var contracts: [Instrument] = []
    @State private var selected: Int32?
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("‹ Back to results", action: back)
            Text("\(underlying.symbol) options · \(underlying.currency)").font(.headline)
            if !chains.isEmpty {
                Picker("Class / exchange", selection: $chainIndex) {
                    ForEach(chains.indices, id: \.self) { index in
                        Text("\(chains[index].tradingClass) · \(chains[index].exchange) · ×\(chains[index].multiplier)").tag(index)
                    }
                }
                HStack {
                    Picker("Expiry", selection: $expiry) {
                        ForEach(chains[chainIndex].expirations, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Right", selection: $call) { Text("Call").tag(true); Text("Put").tag(false) }
                        .pickerStyle(.segmented)
                }
            }
            if loading { ProgressView("Loading listed contracts…").controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red); Button("Retry") { retry += 1 } }
            List(selection: $selected) {
                ForEach(contracts, id: \.contractId) { i in
                    InstrumentResultRow(instrument: i).tag(i.contractId)
                        .onTapGesture(count: 2) { select(i) }
                }
            }
            .focused($contractsFocused)
            Button("Open quote") {
                if let i = contracts.first(where: { $0.contractId == selected }) { select(i) }
            }.disabled(selected == nil).keyboardShortcut(.defaultAction)
        }
        .onChange(of: chainIndex) { _, index in expiry = chains[index].expirations.first ?? "" }
        .task(id: retry) {
            loading = true; error = nil
            do {
                let found = try await store.searchChains(underlying)
                try Task.checkCancellation()
                chains = found; chainIndex = 0
                expiry = found.first?.expirations.first ?? ""
                if found.isEmpty { error = "No listed option chains available." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? ActionError)?.message ?? error.localizedDescription
            }
            loading = false
        }
        .task(id: "\(chainIndex)|\(expiry)|\(call)|\(retry)") {
            contracts = []; selected = nil
            guard chains.indices.contains(chainIndex), !expiry.isEmpty else { return }
            loading = true; error = nil
            do {
                let found = try await store.searchContracts(underlying, chain: chains[chainIndex], expiry: expiry, call: call)
                try Task.checkCancellation()
                contracts = found; selected = found.first?.contractId
                contractsFocused = true
                if found.isEmpty { error = "No contracts listed for this expiry and right." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? ActionError)?.message ?? error.localizedDescription
            }
            loading = false
        }
    }
}
