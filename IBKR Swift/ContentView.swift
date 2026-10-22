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
                    .badge(badge(item))
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                if store.connection != .connected {
                    NotConnectedView()
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
            .safeAreaInset(edge: .bottom) { Banners() }
            .overlay(alignment: .topTrailing) { ToastStack() }
        }
        .toolbar { ConnectionBar() }
    }

    /// Counts that need attention: working orders, running strategies.
    private func badge(_ item: SidebarItem) -> Int {
        guard store.connection == .connected else { return 0 }
        switch item {
        case .orders: return store.openOrderCount
        case .options: return store.activeStrategyCount
        default: return 0
        }
    }
}

private struct NotConnectedView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let address = "\(store.host):\(String(store.port))"
        if store.connection == .connecting {
            ContentUnavailableView("Connecting…", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connecting to IB Gateway at \(address)."))
        } else if let next = store.nextAttempt {
            ContentUnavailableView {
                Label("Waiting for IB Gateway", systemImage: "bolt.horizontal.circle")
            } description: {
                VStack(spacing: 6) {
                    Text("Connecting automatically to \(address) once it's running and logged in.")
                    if let error = store.lastAttemptError { Text(error).foregroundStyle(.secondary) }
                    Text("Next try \(next, style: .relative).").monospacedDigit()
                }
            }
        } else {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connect to IB Gateway at \(address)."))
        }
    }
}

private struct Banners: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.linkProblem {
                Banner(icon: "wifi.exclamationmark", tint: .orange,
                       text: "\(problem) Orders and positions may be out of date until it's back.")
            }
            if let error = store.lastError {
                Banner(icon: "exclamationmark.triangle.fill", tint: .red, text: error) { store.lastError = nil }
            }
        }
    }
}

#Preview {
    ContentView().environment(AppStore())
}
