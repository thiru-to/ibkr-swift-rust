//
//  QuickBuyShortcuts.swift
//  IBKR Swift
//
//  Options Quick Buy: user-set keyboard shortcuts, the Settings pane that records them,
//  and the LIVE confirmation sheet. Shortcuts are off until set, must use ⌘ or ⌃, and can
//  never be Return/Enter/Space/Tab/Esc. They only work while the Options screen shows.
//

import AppKit
import IbkrCore
import SwiftUI

enum QuickBuyKeys {
    static let symbol = "quickBuy.symbol"
    static let quantity = "quickBuy.quantity"
    static let callShortcut = "quickBuy.shortcut.call"
    static let putShortcut = "quickBuy.shortcut.put"
}

struct Shortcut: Codable, Equatable {
    /// Lowercased character, from `charactersIgnoringModifiers`.
    var key: String
    /// `NSEvent.ModifierFlags` raw value (device-independent bits only).
    var modifiers: UInt

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }

    /// Stored as JSON in UserDefaults; "" = no shortcut.
    static func decode(_ raw: String) -> Shortcut? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let s = try? JSONDecoder().decode(Shortcut.self, from: data), s.key.count == 1 else { return nil }
        return s
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// ⌘-shortcuts the system or this app already uses.
    private static let reservedCommandKeys: Set<String> = ["q", "w", "h", "m", ",", "n", "c", "v", "x", "a", "z", "k", "r"]

    /// Builds a shortcut from a key press, or says why it can't be one.
    static func from(_ event: NSEvent) -> Result<Shortcut, ShortcutError> {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // Return, Enter, Tab, Space, Esc: never usable for an order.
        let refused: Set<UInt16> = [36, 76, 48, 49, 53]
        if refused.contains(event.keyCode) { return .failure(.init("Return, Enter, Tab, Space and Esc can't be used.")) }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0xF700 else {
            return .failure(.init("Use a letter, digit or punctuation key."))
        }
        guard flags.contains(.command) || flags.contains(.control) else {
            return .failure(.init("Include ⌘ or ⌃, so typing in a field can't place an order."))
        }
        if flags == .command, reservedCommandKeys.contains(chars) {
            return .failure(.init("⌘\(chars.uppercased()) is already used."))
        }
        return .success(Shortcut(key: chars, modifiers: flags.rawValue))
    }
}

struct ShortcutError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Click, then press a key combination. Esc cancels; Delete clears.
struct ShortcutRecorder: View {
    @Binding var raw: String
    /// The other Quick Buy shortcut, which this one can't duplicate.
    let other: String

    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button(label) { recording ? stop() : start() }
                    .frame(minWidth: 140)
                if Shortcut.decode(raw) != nil && !recording {
                    Button { raw = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove shortcut")
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return "Press keys… (Esc cancels)" }
        return Shortcut.decode(raw)?.display ?? "Record Shortcut"
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            switch event.keyCode {
            case 53: stop() // Esc
            case 51, 117: raw = ""; stop() // Delete, Forward Delete
            default:
                switch Shortcut.from(event) {
                case .failure(let e): problem = e.message
                case .success(let s):
                    if Shortcut.decode(other) == s {
                        problem = "Already used by the other Quick Buy button."
                    } else {
                        raw = s.encoded
                        problem = nil
                        stop()
                    }
                }
            }
            return nil // swallow while recording
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct SettingsView: View {
    @AppStorage(QuickBuyKeys.symbol) private var symbol = "SPY"
    @AppStorage(QuickBuyKeys.quantity) private var quantity = 10
    @AppStorage(QuickBuyKeys.callShortcut) private var callShortcut = ""
    @AppStorage(QuickBuyKeys.putShortcut) private var putShortcut = ""

    var body: some View {
        Form {
            Section {
                TextField("Underlying", text: $symbol)
                Stepper("Contracts: \(quantity)", value: $quantity, in: 1...500)
            } header: {
                Text("Quick Buy")
            } footer: {
                Text("Market buy of at-the-money contracts on the nearest expiry, with the ticket's exits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Buy ATM Call") { ShortcutRecorder(raw: $callShortcut, other: putShortcut) }
                LabeledContent("Buy ATM Put") { ShortcutRecorder(raw: $putShortcut, other: callShortcut) }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Work only while the Options screen is showing. On paper a shortcut buys right away; on LIVE it opens a confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Quick Buy waiting for LIVE confirmation.
struct QuickBuyRequest: Identifiable {
    let id = UUID()
    let spec: StrategySpec
}

extension View {
    /// Adds the shortcut only when one is set.
    @ViewBuilder
    func quickBuyShortcut(_ shortcut: Shortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

/// LIVE confirmation for Quick Buy. Cancel is the default (Return/Esc); buying takes a click.
struct QuickBuyConfirmSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let summary: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Buy now?").font(.title2.bold())
            Text(summary).monospacedDigit().textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                // Deliberately no keyboard shortcut: a LIVE buy takes a click.
                Button(store.isLive ? "Buy LIVE" : "Buy Paper") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isLive ? .red : .accentColor)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
