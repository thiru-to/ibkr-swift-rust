import IbkrCore
import SwiftUI

enum QuoteChartIndicator: Int, CaseIterable, Identifiable {
    case orb15 = 1, orb30 = 2, premarket = 4, previousDay = 8, visible = 16

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .orb15: "ORB 15 · 9:30–9:44"
        case .orb30: "ORB 30 · 9:30–9:59"
        case .premarket: "PMH / PML · 4:00–9:29"
        case .previousDay: "PDH / PDL · previous regular session"
        case .visible: "Visible high / low"
        }
    }
    var shortTitle: String {
        switch self {
        case .orb15: "ORB 15"
        case .orb30: "ORB 30"
        case .premarket: "PMH / PML"
        case .previousDay: "PDH / PDL"
        case .visible: "Visible H / L"
        }
    }
    var color: Color {
        switch self {
        case .orb15: .orange
        case .orb30: .purple
        case .premarket: .cyan
        case .previousDay: .blue
        case .visible: .secondary
        }
    }

    func enabled(in selection: Int) -> Bool { selection & rawValue != 0 }

    func range(in levels: ChartSessionLevels?) -> ChartPriceRange? {
        switch self {
        case .orb15: levels?.orb15
        case .orb30: levels?.orb30
        case .premarket: levels?.premarket
        case .previousDay: levels?.previousDay
        case .visible: nil
        }
    }

    func lines(_ range: ChartPriceRange) -> [ChartLevel] {
        let labels: (String, String) = switch self {
        case .orb15: ("ORB15 H", "ORB15 L")
        case .orb30: ("ORB30 H", "ORB30 L")
        case .premarket: ("PMH", "PML")
        case .previousDay: ("PDH", "PDL")
        case .visible: ("View H", "View L")
        }
        return [ChartLevel(id: labels.0, price: range.high, color: color, low: false),
                ChartLevel(id: labels.1, price: range.low, color: color, low: true)]
    }
}

struct ChartLevel: Identifiable {
    let id: String
    let price: Double
    let color: Color
    let low: Bool

    var priceLabel: String { price.formatted(.number.precision(.fractionLength(2...4))) }
}

struct ChartIndicatorMenu: View {
    @Binding var selection: Int

    var body: some View {
        Menu {
            Section("Session times: New York") {
                ForEach(QuoteChartIndicator.allCases) { indicator in
                    Toggle(indicator.title, isOn: Binding(
                        get: { indicator.enabled(in: selection) },
                        set: { enabled in
                            if enabled { selection |= indicator.rawValue }
                            else { selection &= ~indicator.rawValue }
                        }
                    ))
                }
            }
            Divider()
            Button("Hide all indicators") { selection = 0 }
                .disabled(selection == 0)
        } label: {
            Label("Indicators\(selection == 0 ? "" : " (\(QuoteChartIndicator.allCases.filter { $0.enabled(in: selection) }.count))")",
                  systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Session levels use New York time. Visible high/low follows pan and zoom.")
    }
}
