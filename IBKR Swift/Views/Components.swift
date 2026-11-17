//
//  Components.swift
//  IBKR Swift
//
//  Small shared building blocks: pills, cards, banners and toasts.
//

import SwiftUI

/// Opaque, adaptive surfaces keep the trading workspace inexpensive to draw.
enum AppTheme {
    static let accent = Color.indigo
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.08)
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let cardRadius: CGFloat = 12
}

struct SectionHeading: View {
    let title: String
    let icon: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WorkspaceEmptyState: View {
    let title: String
    let icon: String
    let description: String
    var tint: Color = AppTheme.accent

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .background(tint.opacity(0.1), in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.canvas)
    }
}

/// A short colored label in a capsule: modes, order statuses, strategy states.
struct Pill: View {
    let text: String
    let color: Color
    /// Solid background with white text, for things that must stand out (LIVE).
    var solid = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(solid ? color : color.opacity(0.12), in: Capsule())
            .foregroundStyle(solid ? .white : color)
            .fixedSize()
    }
}

extension View {
    /// Rounded, lightly filled container.
    func card(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: .rect(cornerRadius: AppTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cardRadius)
                    .strokeBorder(tint?.opacity(0.22) ?? AppTheme.border)
                    .allowsHitTesting(false)
            }
    }
}

/// Caption over a large number.
struct StatCard: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var icon: String = "chart.bar"
    var accent: Color = AppTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: icon).foregroundStyle(accent).accessibilityHidden(true)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .monospacedDigit()
        .card(tint: accent)
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
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", action: dismiss).controlSize(.small)
            }
        }
        .padding(12)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.toasts) { toast in
                Button { store.dismissToast(toast.id) } label: {
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
                    .background(AppTheme.surface, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(toast.tone.color.opacity(0.4)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .help("Dismiss notification")
                .accessibilityHint("Dismiss notification")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .animation(reduceMotion ? nil : .snappy, value: store.toasts.map(\.id))
    }
}
