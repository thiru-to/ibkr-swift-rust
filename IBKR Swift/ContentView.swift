//
//  ContentView.swift
//  IBKR Swift
//
//  Created by Aingaran on 2026-10-22.
//

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case account = "Account"
    case positions = "Positions"
    case quote = "Quote"
    case options = "Options"
    case orders = "Orders"

    var id: Self { self }

    var icon: String {
        switch self {
        case .account: "dollarsign.circle"
        case .positions: "list.bullet.rectangle"
        case .quote: "chart.line.uptrend.xyaxis"
        case .options: "scope"
        case .orders: "arrow.left.arrow.right"
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarItem? = .account

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                if store.connection != .connected {
                    ContentUnavailableView(
                        store.connection == .connecting ? "Connecting…" : "Not Connected",
                        systemImage: "bolt.horizontal.circle",
                        description: Text("Connect to IB Gateway at \(store.host):\(String(store.port)).")
                    )
                } else {
                    switch selection ?? .account {
                    case .account: AccountView()
                    case .positions: PositionsView()
                    case .quote: QuoteView()
                    case .options: OptionsView()
                    case .orders: OrdersView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { ErrorBanner() }
        }
        .toolbar { ConnectionBar() }
    }
}

private struct ErrorBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let error = store.lastError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { store.lastError = nil }
            }
            .padding(10)
            .background(.bar)
        }
    }
}

#Preview {
    ContentView().environment(AppStore())
}
