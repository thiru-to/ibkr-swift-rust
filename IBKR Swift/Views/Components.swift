//
//  Components.swift
//  IBKR Swift
//
//  Small shared building blocks: pills, cards, banners and toasts.
//

import SwiftUI

/// A short colored label in a capsule: modes, order statuses, strategy states.
struct Pill: View {
    let text: String
    let color: Color
    /// Solid background with white text, for things that must stand out (LIVE).
    var solid = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(solid ? color : color.opacity(0.18), in: Capsule())
            .foregroundStyle(solid ? .white : color)
    }
}

extension View {
    /// Rounded, lightly filled container.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

/// Caption over a large number.
struct StatCard: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint)
        }
        .monospacedDigit()
        .card()
    }
}

/// Green for gains, red for losses.
func pnlColor(_ value: Double?) -> Color {
    guard let value, value != 0 else { return .primary }
    return value > 0 ? .green : .red
}

/// A full-width notice pinned to the bottom of the window.
struct Banner: View {
    let icon: String
    let tint: Color
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
            if let dismiss {
                Button("Dismiss", action: dismiss).controlSize(.small)
            }
        }
        .padding(10)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

extension Toast.Tone {
    var color: Color {
        switch self {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        case .failure: .red
        }
    }

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

/// Order events and connection changes, top-right; click to dismiss.
struct ToastStack: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.toasts) { toast in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: toast.tone.icon)
                        .font(.title3)
                        .foregroundStyle(toast.tone.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title).font(.headline)
                        Text(toast.detail).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(12)
                .frame(width: 320, alignment: .leading)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(toast.tone.color.opacity(0.4)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .onTapGesture { store.dismissToast(toast.id) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .animation(.snappy, value: store.toasts.map(\.id))
    }
}
