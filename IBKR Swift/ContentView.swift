//
//  ContentView.swift
//  IBKR Swift
//
//  Created by Aingaran on 2026-10-22.
//

import AppKit
import IbkrCore
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

    var tint: Color {
        switch self {
        case .account: .indigo
        case .positions: .teal
        case .quote: .blue
        case .options: .purple
        case .orders: .orange
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarItem? = .account
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarNavigation(selection: $selection, columns: $columns)
                .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                // Collapsed sidebar: keep an icon rail so screens stay one click away.
                if columns == .detailOnly {
                    IconRail(selection: $selection, columns: $columns)
                    Divider()
                }
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom) { Banners() }
            .overlay(alignment: .topTrailing) { ToastStack() }
            .background(AppTheme.canvas)
        }
        .tint(AppTheme.accent)
        .toolbar { ConnectionBar() }
    }

    @ViewBuilder
    private var screen: some View {
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
    }

}

/// Keep badge observations in navigation so order updates don't invalidate the screen host.
private struct SidebarNavigation: View {
    @Binding var selection: SidebarItem?
    @Binding var columns: NavigationSplitViewVisibility
    @State private var windowControlsInset: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                SidebarBrand()
                SidebarBrand(compact: true)
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("IBKR Swift")
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 52)
                .padding(.leading, windowControlsInset)
                .padding(.trailing, 16)
            List(selection: $selection) {
                Section("Workspace") {
                    ForEach(SidebarItem.allCases) { item in
                        NavigationRow(item: item).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 38)
            ConnectionStatus()
                .padding(.horizontal, 16)
                .padding(.top, 12)
            HStack {
                SidebarToggleButton(columns: $columns)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SidebarWindowControlsInset(inset: $windowControlsInset))
    }
}

private struct SidebarBrand: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 34, height: 34)
                .background(AppTheme.accent.opacity(0.1), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("IBKR Swift").font(.headline)
                if !compact {
                    Text("Trading workspace").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
    }
}

/// Reserve the native window buttons' space when the sidebar extends into the title bar.
private struct SidebarWindowControlsInset: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> WindowControlsInsetView {
        let view = WindowControlsInsetView()
        view.onChange = { inset = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowControlsInsetView, context: Context) {}

    final class WindowControlsInsetView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                             NSWindow.didResizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateInset),
                                                           name: name, object: window)
                }
            }
            updateInset()
        }

        @objc private func updateInset() {
            guard let window else { return }
            let rightEdge = window.styleMask.contains(.fullScreen) ? 0 :
                [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                    .compactMap { window.standardWindowButton($0) }
                    .map { $0.convert($0.bounds, to: nil).maxX }
                    .max() ?? 0
            let leading = max(16, rightEdge + 12)
            // Window notifications can arrive during a SwiftUI layout pass.
            Task { @MainActor [weak self] in self?.onChange?(leading) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private struct SidebarToggleButton: View {
    @Binding var columns: NavigationSplitViewVisibility

    private var isCollapsed: Bool { columns == .detailOnly }

    var body: some View {
        Button {
            withAnimation {
                columns = isCollapsed ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isCollapsed ? "Show sidebar" : "Hide sidebar")
        .accessibilityLabel(isCollapsed ? "Show sidebar" : "Hide sidebar")
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

private struct NavigationRow: View {
    @Environment(AppStore.self) private var store
    let item: SidebarItem

    var body: some View {
        Label {
            Text(item.rawValue).fontWeight(.medium)
        } icon: {
            Image(systemName: item.icon).foregroundStyle(item.tint)
        }
        .padding(.vertical, 3)
        .badge(navigationBadge(item, store: store))
    }
}

private func navigationBadge(_ item: SidebarItem, store: AppStore) -> Int {
    guard store.connection == .connected else { return 0 }
    switch item {
    case .orders: return store.openOrderCount
    case .options: return store.activeStrategyCount
    default: return 0
    }
}

private struct ConnectionStatus: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium))
                Text(store.connection == .connected ? store.account : "IB Gateway")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.07), in: .rect(cornerRadius: 10))
    }

    private var title: String {
        if store.linkProblem != nil { return "Reconnecting" }
        switch store.connection {
        case .connected: return "Gateway connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Gateway offline"
        }
    }

    private var tint: Color {
        if store.linkProblem != nil { return .orange }
        return store.connection == .connected ? .green : .secondary
    }
}

/// Icon-only navigation shown while the sidebar is collapsed.
private struct IconRail: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: SidebarItem?
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        VStack(spacing: 8) {
            ForEach(SidebarItem.allCases) { item in
                let selected = (selection ?? .account) == item
                Button { selection = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 15))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(selected ? item.tint : .secondary)
                        .background(selected ? item.tint.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            let n = navigationBadge(item, store: store)
                            if n > 0 {
                                Text("\(n)")
                                    .font(.system(size: 9, weight: .bold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 13, minHeight: 13)
                                    .background(.red, in: Capsule())
                                    .foregroundStyle(.white)
                                    .offset(x: 4, y: -3)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.rawValue)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            SidebarToggleButton(columns: $columns)
        }
        .padding(.vertical, 16)
        .frame(width: 56)
    }
}

private struct NotConnectedView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let address = "\(store.host):\(String(store.port))"
        VStack(spacing: 0) {
            WorkspaceEmptyState(
                title: store.connection == .connecting ? "Connecting to your workspace" : "Your workspace is ready",
                icon: "bolt.horizontal.circle",
                description: "Start IB Gateway and sign in to view your account, quotes, and orders.")
                .frame(maxHeight: 240)
            VStack(spacing: 12) {
                Label(address, systemImage: "network")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                if store.connection == .connecting {
                    ProgressView("Connecting…").controlSize(.small)
                } else if let next = store.nextAttempt {
                    Text("Retrying \(next, style: .relative)").font(.callout).monospacedDigit()
                    Button("Connect now", systemImage: "bolt.fill") { Task { await store.connect() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect to Gateway", systemImage: "bolt.fill") { Task { await store.connect() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                if let error = store.lastAttemptError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .frame(maxWidth: 420)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Banners: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let reason = store.risk?.halted {
                Banner(icon: "hand.raised.fill", tint: .red,
                       text: "Trading halted for today: \(reason). New entries are blocked until the next trading day; exits still work.")
            }
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
