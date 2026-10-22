//! Option chains, contract resolution (by option spec or contract id) and tick-size rounding.

use std::collections::BTreeSet;

use futures::StreamExt;
use ibapi::Client;
use ibapi::contracts::{Contract, ContractDetails, SecurityType};
use ibapi::subscriptions::SubscriptionItemStreamExt;

use crate::types::*;

/// Merges IB's per-exchange chains into one. IB lists a chain per exchange and per
/// trading class; non-standard classes (e.g. "2SPY" for adjusted contracts) are ignored
/// when a class matching the symbol exists.
pub async fn option_chain(client: &Client, symbol: &str) -> Result<OptionChain, IbkrError> {
    let symbol = symbol.trim().to_uppercase();
    let details = client.contract_details(&Contract::stock(symbol.clone()).build()).await?;
    let underlying = details
        .first()
        .ok_or_else(|| IbkrError::Invalid { message: format!("unknown symbol {symbol}") })?;
    let conid = underlying.contract.contract_id;

    let mut chains = Vec::new();
    let mut sub = client.option_chain(&symbol, SecurityType::Stock, conid).subscribe().await?.filter_data();
    while let Some(item) = sub.next().await {
        match item {
            Ok(chain) => chains.push(chain),
            Err(_) => break, // end of stream
        }
    }
    if chains.is_empty() {
        return Err(IbkrError::Invalid { message: format!("no options listed for {symbol}") });
    }

    let standard = chains.iter().any(|c| c.trading_class == symbol);
    let mut expirations = BTreeSet::new();
    let mut strikes: Vec<f64> = Vec::new();
    let mut multiplier = 100.0;
    for c in chains.iter().filter(|c| !standard || c.trading_class == symbol) {
        expirations.extend(c.expirations.iter().cloned());
        strikes.extend(c.strikes.iter().copied());
        if let Ok(m) = c.multiplier.parse() {
            multiplier = m;
        }
    }
    strikes.sort_by(f64::total_cmp);
    strikes.dedup_by(|a, b| (*a - *b).abs() < 1e-9);

    Ok(OptionChain {
        symbol,
        underlying_conid: conid,
        expirations: expirations.into_iter().collect(),
        strikes,
        multiplier,
    })
}

/// A fully-resolved contract plus what's needed to price orders on it.
pub struct ResolvedContract {
    pub contract: Contract,
    pub local_symbol: String,
    pub multiplier: f64,
    /// (low_edge, increment), ascending.
    pub increments: Vec<(f64, f64)>,
}

pub fn option_contract(spec: &OptionSpec) -> Result<Contract, IbkrError> {
    let (y, m, d) = parse_expiry(&spec.expiry)?;
    let symbol = spec.symbol.trim().to_uppercase();
    let builder = match spec.right {
        OptionRight::Call => Contract::call(symbol),
        OptionRight::Put => Contract::put(symbol),
    };
    Ok(builder.strike(spec.strike).expires_on(y, m, d).build())
}

pub async fn resolve_option(client: &Client, spec: &OptionSpec) -> Result<ResolvedContract, IbkrError> {
    let details = client.contract_details(&option_contract(spec)?).await.map_err(|e| IbkrError::Invalid {
        message: format!("{} {} {:?} {}: {e}", spec.symbol, spec.expiry, spec.right, spec.strike),
    })?;
    // Prefer the standard trading class if several come back.
    let symbol = spec.symbol.trim().to_uppercase();
    let d: &ContractDetails = details
        .iter()
        .find(|d| d.contract.trading_class == symbol)
        .or_else(|| details.first())
        .ok_or_else(|| IbkrError::Invalid {
            message: format!("no {symbol} {:?} {} expiring {}", spec.right, spec.strike, spec.expiry),
        })?;
    Ok(resolved(client, d).await)
}

/// Resolves a position's contract (any type) for SMART-routed quotes and orders.
pub async fn resolve_contract_id(client: &Client, contract_id: i32) -> Result<ResolvedContract, IbkrError> {
    let query = Contract { contract_id, exchange: "SMART".into(), ..Default::default() };
    let details = client.contract_details(&query).await?;
    let d = details
        .first()
        .ok_or_else(|| IbkrError::Invalid { message: format!("IB has no contract {contract_id}") })?;
    Ok(resolved(client, d).await)
}

async fn resolved(client: &Client, d: &ContractDetails) -> ResolvedContract {
    // contract_details returns "YYYYMMDD HH:MM:SS TZ", which IB rejects on orders (10372).
    let mut contract = d.contract.clone();
    if let Some(date) = contract.last_trade_date_or_contract_month.split_whitespace().next() {
        contract.last_trade_date_or_contract_month = date.to_string();
    }

    // Stocks report no multiplier; options always do.
    let multiplier = d.contract.multiplier.parse().unwrap_or(1.0);
    let mut increments = vec![(0.0, if d.min_tick > 0.0 { d.min_tick } else { 0.01 })];
    // market_rule_ids line up with valid exchanges; IB uses one rule for SMART-routed US options.
    if let Some(rule_id) = d.market_rule_ids.iter().find_map(|s| s.trim().parse::<i32>().ok())
        && let Ok(rule) = client.market_rule(rule_id).await
        && !rule.price_increments.is_empty()
    {
        increments = rule.price_increments.iter().map(|p| (p.low_edge, p.increment)).collect();
        increments.sort_by(|a, b| a.0.total_cmp(&b.0));
    }

    ResolvedContract {
        local_symbol: d.contract.local_symbol.clone(),
        contract,
        multiplier,
        increments,
    }
}

pub fn parse_expiry(expiry: &str) -> Result<(u16, u8, u8), IbkrError> {
    let bad = || IbkrError::Invalid { message: format!("expiry must be YYYYMMDD, got {expiry:?}") };
    if expiry.len() != 8 || !expiry.bytes().all(|b| b.is_ascii_digit()) {
        return Err(bad());
    }
    let y = expiry[0..4].parse().map_err(|_| bad())?;
    let m = expiry[4..6].parse().map_err(|_| bad())?;
    let d = expiry[6..8].parse().map_err(|_| bad())?;
    Ok((y, m, d))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Round {
    Up,
    Down,
    Nearest,
}

/// The tick size that applies at `price` (bands are keyed by their low edge).
pub fn tick_at(price: f64, increments: &[(f64, f64)]) -> f64 {
    increments
        .iter()
        .rev()
        .find(|(low, _)| price + 1e-9 >= *low)
        .or(increments.first())
        .map_or(0.01, |(_, inc)| *inc)
}

/// Rounds to a valid tick for the band the price falls in.
pub fn round_to_tick(price: f64, increments: &[(f64, f64)], dir: Round) -> f64 {
    let tick = tick_at(price, increments);
    let steps = price / tick;
    let steps = match dir {
        Round::Up => (steps - 1e-9).ceil(),
        Round::Down => (steps + 1e-9).floor(),
        Round::Nearest => steps.round(),
    };
    // Clean float noise (e.g. 1.2000000000000002).
    (steps * tick * 1e6).round() / 1e6
}

#[cfg(test)]
mod tests {
    use super::*;

    // Typical US equity option rule: $0.01 below $3, $0.05 at/above $3.
    const NICKEL: &[(f64, f64)] = &[(0.0, 0.01), (3.0, 0.05)];

    #[test]
    fn rounds_within_bands() {
        assert_eq!(round_to_tick(1.234, NICKEL, Round::Up), 1.24);
        assert_eq!(round_to_tick(1.234, NICKEL, Round::Down), 1.23);
        assert_eq!(round_to_tick(1.23, NICKEL, Round::Up), 1.23, "already on a tick");
        assert_eq!(round_to_tick(3.12, NICKEL, Round::Up), 3.15);
        assert_eq!(round_to_tick(3.12, NICKEL, Round::Down), 3.10);
        assert_eq!(round_to_tick(0.1 + 0.2, NICKEL, Round::Down), 0.3, "float noise");
    }

    #[test]
    fn parses_expiry() {
        assert_eq!(parse_expiry("20261022").unwrap(), (2026, 10, 22));
        assert!(parse_expiry("2026-10-22").is_err());
    }
}
