//
//  Format.swift
//  IBKR Swift
//

import Foundation

extension Optional where Wrapped == Double {
    /// "—" for missing values.
    func formatted(digits: Int = 2) -> String {
        guard let value = self else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    func money(_ currency: String) -> String {
        guard let value = self else { return "—" }
        return value.formatted(.currency(code: currency.isEmpty ? "USD" : currency))
    }
}

extension Double {
    /// Quantities: no decimals unless fractional.
    var quantity: String {
        formatted(.number.precision(.fractionLength(0...4)))
    }
}
