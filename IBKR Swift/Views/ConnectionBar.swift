//
//  ConnectionBar.swift
//  IBKR Swift
//

import SwiftUI

struct ConnectionBar: ToolbarContent {
    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        ToolbarItemGroup(placement: .primaryAction) {
            if store.connection == .connected {
                ModeBadge(isLive: store.isLive)
                Text(store.account).monospaced().foregroundStyle(.secondary)
                Button("Disconnect", systemImage: "bolt.slash") {
                    Task { await store.disconnect() }
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
        Text(isLive ? "LIVE" : "PAPER")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isLive ? Color.red : Color.green, in: Capsule())
            .foregroundStyle(.white)
    }
}
