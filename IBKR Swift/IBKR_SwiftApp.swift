//
//  IBKR_SwiftApp.swift
//  IBKR Swift
//
//  Created by Aingaran on 2026-10-22.
//

import AppKit
import SwiftUI

@main
struct IBKR_SwiftApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandMenu("Account") {
                @Bindable var store = store
                Picker("Trading Mode", selection: $store.mode) {
                    ForEach(AppStore.TradingMode.allCases) { mode in
                        Text("\(mode.title) (port \(String(mode.defaultPort)))").tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(store.connection != .disconnected)

                if store.connection != .disconnected {
                    Text("Disconnect to change mode")
                }
            }
        }
    }
}

/// Confirms quitting while a strategy still depends on the app (trigger not yet fired,
/// entry in flight, or an app-managed EOD close). Filled positions keep their IB exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let count = store?.appDependentStrategies, count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with \(count) active \(count == 1 ? "strategy" : "strategies")?"
        alert.informativeText = "Armed triggers stop and in-flight entries lose tracking. Positions that are already protected keep their exit orders at IB."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
