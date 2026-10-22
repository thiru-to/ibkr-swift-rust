//
//  IBKR_SwiftApp.swift
//  IBKR Swift
//
//  Created by Aingaran on 2026-10-22.
//

import SwiftUI

@main
struct IBKR_SwiftApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1000, height: 640)
    }
}
