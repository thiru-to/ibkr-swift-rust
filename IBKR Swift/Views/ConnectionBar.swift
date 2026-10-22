//
//  ConnectionBar.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

struct ConnectionBar: ToolbarContent {
    @Environment(AppStore.self) private var store
    @State private var confirmDisconnect = false

    var body: some ToolbarContent {
        @Bindable var store = store
        ToolbarItemGroup(placement: .primaryAction) {
            if store.connection == .connected {
                Circle()
                    .fill(store.linkProblem == nil ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .help(store.linkProblem ?? "Connected to IB Gateway")
                ModeBadge(isLive: store.isLive)
                Text(store.account).monospaced().foregroundStyle(.secondary)
                if store.risk?.halted != nil {
                    Pill(text: "HALTED", color: .red, solid: true)
                        .help(store.risk?.halted ?? "")
                } else {
                    HaltButton()
                }
                Button("Disconnect", systemImage: "bolt.slash") {
                    if store.appDependentStrategies > 0 {
                        confirmDisconnect = true
                    } else {
                        Task { await store.disconnect() }
                    }
                }
                .confirmationDialog("Disconnect with active strategies?", isPresented: $confirmDisconnect) {
                    Button("Disconnect", role: .destructive) { Task { await store.disconnect() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Armed triggers stop and in-flight entries lose tracking. Protected positions keep their exit orders at IB.")
                }
            } else {
                ModeBadge(isLive: store.mode == .live)
                    .help("Change in the Account menu")
                TextField("Host", text: $store.host).frame(width: 110)
                TextField("Port", value: $store.port, format: .number.grouping(.never)).frame(width: 60)
                TextField("Client ID", value: $store.clientId, format: .number.grouping(.never)).frame(width: 50)
                    .help("Client ID (must be unique per API connection)")
                Button("Connect", systemImage: "bolt") {
                    Task { await store.connect() }
                }
                .disabled(store.connection == .connecting)
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

struct ModeBadge: View {
    let isLive: Bool

    var body: some View {
        Pill(text: isLive ? "LIVE" : "PAPER", color: isLive ? .red : .green, solid: true)
    }
}
