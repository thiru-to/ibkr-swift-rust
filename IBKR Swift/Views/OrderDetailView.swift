//
//  OrderDetailView.swift
//  IBKR Swift
//
//  One order's details and timeline. IB sends no submit or acknowledgement time of its
//  own: its only times are each execution's and a completed order's, in whole seconds.
//  The app's times are its system clock as each event arrived, to the millisecond
//  (`OrderTimeline` in orders.rs). Display only.
//

import IbkrCore
import SwiftUI

/// Identifies an order across its provisional key → perm id migration.
struct OrderRef: Identifiable, Hashable {
    let id: String
    let clientId: Int32
    let orderId: Int32
    let permId: Int64

    init(_ o: OrderInfo) {
        id = o.id
        clientId = o.clientId
        orderId = o.orderId
        permId = o.permId
    }
}

nonisolated enum AppTime {
    /// "Nov 16 14:23:45.123" in local time, always on the 24-hour clock (a 12-hour
    /// locale with the AM/PM marker omitted showed 14:52 as "02:52").
    static func label(_ ms: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    nonisolated(unsafe) private static let formatter: DateFormatter = {  // DateFormatter is thread-safe
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm:ss.SSS"
        return f
    }()

    /// "+412 ms" / "+1.234 s" after `start`.
    static func delta(_ ms: Int64?, from start: Int64?) -> String {
        guard let ms, let start else { return "" }
        let d = ms - start
        return abs(d) >= 10_000 ? String(format: "+%.3f s", Double(d) / 1000) : "+\(d) ms"
    }
}

struct OrderDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ref: OrderRef

    private var order: OrderInfo? {
        store.orders.first { $0.id == ref.id }
            ?? store.orders.first { ref.permId != 0 && $0.permId == ref.permId }
            ?? store.orders.first { $0.clientId == ref.clientId && $0.orderId == ref.orderId && $0.orderId > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let o = order {
                header(o)
                Divider()
                timeline(o)
                executions(o)
            } else {
                ContentUnavailableView("Order No Longer Listed", systemImage: "tray")
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 460)
        .monospacedDigit()
    }

    private func header(_ o: OrderInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(o.action.uppercased()).font(.title2.bold()).foregroundStyle(o.isBuy ? .green : .red)
                Text("\(o.quantity.quantity) \(o.displaySymbol)").font(.title2.bold()).monospaced()
                Spacer()
                StatusPill(order: o)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow {
                    field("Type", "\(o.orderType) · \(o.tif)")
                    field("Price", price(o))
                    field("Filled", "\(o.filled.quantity) / \(o.quantity.quantity) @ \(o.averageFillPrice.formatted(digits: 2))")
                }
                GridRow {
                    field("Order id", o.orderId > 0 ? String(o.orderId) : "—")
                    field("Perm id", o.permId != 0 ? String(o.permId) : "—")
                    field("Client", o.clientId == 0 ? "TWS (0)" : String(o.clientId) + (o.clientId == store.sessionClientId ? " (this app)" : ""))
                }
                GridRow {
                    field("Account", o.account)
                    field("Contract id", String(o.contractId))
                    field("Status", o.status)
                }
            }
            .font(.callout)
            if !o.detail.isEmpty {
                Text(o.detail).font(.callout).foregroundStyle(o.group == .inactive ? .red : .secondary).textSelection(.enabled)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private struct Event: Identifiable {
        let id: String
        let name: String
        let ib: String
        let app: Int64?
        let appNote: String
    }

    private func events(_ o: OrderInfo) -> [Event] {
        let t = o.timeline
        let execs = o.executions
        let firstExec = execs.first
        let lastExec = execs.last
        let loaded = t.fromSnapshot ? "before the app was watching" : "—"
        let ended = o.group == .cancelled || o.group == .inactive
        var rows = [
            Event(id: "submit", name: "Submitted", ib: "not sent by IB", app: t.submittedMs,
                  appNote: t.submittedMs == nil ? (o.clientId == store.sessionClientId && !t.fromSnapshot ? "—" : "not placed by this app run") : ""),
            Event(id: "seen", name: "First seen by app", ib: "", app: t.firstSeenMs, appNote: t.fromSnapshot ? "loaded from IB at connect" : ""),
            Event(id: "ack", name: "Acknowledged", ib: "not sent by IB", app: t.ackMs,
                  appNote: t.ackMs != nil ? t.ackStatus : loaded),
            Event(id: "first", name: "First fill", ib: firstExec?.ibTime ?? "—", app: t.firstFillMs,
                  appNote: t.firstFillMs == nil && o.filled > 0 ? loaded : ""),
            Event(id: "filled", name: "Filled", ib: o.group == .filled ? (lastExec?.ibTime ?? "—") : "—", app: t.filledMs,
                  appNote: t.filledMs == nil && o.group == .filled ? loaded : ""),
        ]
        if ended || t.endedMs != nil {
            rows.append(Event(id: "ended", name: o.group == .inactive ? "Rejected / inactive" : "Cancelled", ib: "—", app: t.endedMs,
                              appNote: t.endedMs == nil ? loaded : ""))
        }
        if !o.completedTime.isEmpty {
            rows.append(Event(id: "completed", name: "Completed (IB)", ib: o.completedTime, app: nil, appNote: ""))
        }
        return rows
    }

    private func timeline(_ o: OrderInfo) -> some View {
        let start = o.timeline.submittedMs ?? o.timeline.ackMs ?? o.timeline.firstSeenMs
        return VStack(alignment: .leading, spacing: 6) {
            Text("Timeline").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Event")
                    Text("IB (API) time")
                    Text("App (system) time")
                    Text(o.timeline.submittedMs != nil ? "Since submit" : "Since first seen")
                    Text("")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                ForEach(events(o)) { e in
                    GridRow {
                        Text(e.name)
                        Text(e.ib.isEmpty ? "" : e.ib).foregroundStyle(e.ib.hasPrefix("not") || e.ib == "—" ? .secondary : .primary)
                        Text(e.app.map(AppTime.label) ?? "—").foregroundStyle(e.app == nil ? .secondary : .primary)
                        Text(AppTime.delta(e.app, from: start)).fontWeight(.semibold)
                        Text(e.appNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            Text("IB's times are its server's, in whole seconds (it sends none for submit or acknowledgement). App times are this Mac's clock when each event arrived, to the millisecond.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func executions(_ o: OrderInfo) -> some View {
        if !o.executions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Executions").font(.headline)
                Table(o.executions) {
                    TableColumn("IB time") { (e: OrderExecution) in Text(e.ibTime) }.width(min: 150, ideal: 190)
                    TableColumn("Received (app)") { (e: OrderExecution) in
                        Text(AppTime.label(e.receivedMs) + (e.fromSnapshot ? " (loaded)" : ""))
                            .foregroundStyle(e.fromSnapshot ? .secondary : .primary)
                    }
                    .width(min: 150, ideal: 190)
                    TableColumn("Shares") { (e: OrderExecution) in Text(e.shares.quantity) }.width(55)
                    TableColumn("Price") { (e: OrderExecution) in Text(Optional(e.price).formatted(digits: 2)) }.width(60)
                    TableColumn("Exchange") { (e: OrderExecution) in Text(e.exchange) }.width(70)
                    TableColumn("Exec id") { (e: OrderExecution) in Text(e.execId).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .frame(minHeight: 90, idealHeight: CGFloat(40 + 24 * min(o.executions.count, 6)))
            }
        }
    }

    private func price(_ o: OrderInfo) -> String {
        switch (o.stopPrice, o.limitPrice) {
        case let (stop?, limit?): "stp \(Optional(stop).formatted()) lmt \(Optional(limit).formatted())"
        case let (stop?, nil): "stp \(Optional(stop).formatted())"
        case let (nil, limit?): Optional(limit).formatted()
        case (nil, nil): "market"
        }
    }
}

nonisolated extension OrderExecution: @retroactive Identifiable {
    public var id: String { execId }
}
