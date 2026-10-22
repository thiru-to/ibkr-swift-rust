//
//  OptionMath.swift
//  IBKR Swift
//
//  Black-Scholes for the options P/L simulator. European exercise, no dividends, a flat
//  rate and one volatility for every price: fine for a what-if chart, not for quoting.
//

import Foundation

enum OptionMath {
    /// Annual risk-free rate (continuous). Moves prices far less than volatility does.
    static let riskFreeRate = 0.04
    static let secondsPerYear = 365.0 * 86_400

    static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// Theoretical premium per share. At or past expiry (`years` ≤ 0) it's intrinsic value.
    static func price(call: Bool, spot: Double, strike: Double, years: Double, vol: Double,
                      rate: Double = riskFreeRate) -> Double {
        let intrinsic = max(call ? spot - strike : strike - spot, 0)
        guard years > 0, vol > 0, spot > 0, strike > 0 else { return intrinsic }
        let sd = vol * years.squareRoot()
        let d1 = (log(spot / strike) + (rate + vol * vol / 2) * years) / sd
        let d2 = d1 - sd
        let discount = exp(-rate * years)
        return call
            ? spot * normalCDF(d1) - strike * discount * normalCDF(d2)
            : strike * discount * normalCDF(-d2) - spot * normalCDF(-d1)
    }

    /// The volatility that reproduces `premium`, by bisection over 1%…500%. Nil when no
    /// volatility in that range does (e.g. a premium below intrinsic value).
    static func impliedVol(call: Bool, premium: Double, spot: Double, strike: Double, years: Double) -> Double? {
        guard years > 0, premium > 0, spot > 0 else { return nil }
        func at(_ vol: Double) -> Double { price(call: call, spot: spot, strike: strike, years: years, vol: vol) }
        var lo = 0.01, hi = 5.0
        guard at(lo) <= premium, premium <= at(hi) else { return nil }
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if at(mid) < premium { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Risk-neutral chance the underlying ends above (or below) `level` after `years`.
    static func probability(above: Bool, level: Double, spot: Double, years: Double, vol: Double,
                            rate: Double = riskFreeRate) -> Double {
        guard years > 0, vol > 0, level > 0, spot > 0 else { return above == (spot > level) ? 1 : 0 }
        let d2 = (log(spot / level) + (rate - vol * vol / 2) * years) / (vol * years.squareRoot())
        return above ? normalCDF(d2) : normalCDF(-d2)
    }
}
