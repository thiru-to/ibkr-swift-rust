//
//  PositionsView.swift
//  IBKR Swift
//

import IbkrCore
import SwiftUI

/// Which position the details sheet shows (by id, so it follows live updates).
private struct DetailsTarget: Identifiable {
    let id: Position.ID
}

struct PositionsView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Position.ID?
    @State private var details: DetailsTarget?

    var body: some View {
        Table(store.positions, selection: $selection) {
            TableColumn("Symbol") { p in Text(p.displaySymbol).monospaced().fontWeight(.medium) }
            TableColumn("Type") { p in Pill(text: p.secType, color: p.secType == "OPT" ? .purple : .blue) }.width(50)
            TableColumn("Quantity") { p in Text(p.quantity.quantity).foregroundStyle(p.quantity < 0 ? .red : .primary) }
            TableColumn("Avg Price") { p in Text(Optional(p.averagePrice).formatted(digits: 4)) }
            TableColumn("Currency", value: \.currency).width(60)
            TableColumn("") { p in
                HStack(spacing: 6) {
                    if store.strategy(managing: p) != nil { Pill(text: "STRATEGY", color: .purple) }
                    Button("Details") { details = DetailsTarget(id: p.id) }
                        .controlSize(.small)
                }
            }
            .width(min: 70, ideal: 150)
        }
        .contextMenu(forSelectionType: Position.ID.self) { _ in
        } primaryAction: { ids in
            details = ids.first.map(DetailsTarget.init)
        }
        .monospacedDigit()
        .overlay {
            if store.positions.isEmpty {
                WorkspaceEmptyState(title: "No open positions", icon: "tray",
                                    description: "Your holdings will appear here as they’re reported by IB Gateway.", tint: .teal)
            }
        }
        .sheet(item: $details) { target in
            PositionDetailView(positionId: target.id)
        }
        .navigationTitle("Positions")
    }
}
