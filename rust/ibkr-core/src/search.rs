//! Read-only contract discovery. Never constructs orders or requests quotes for results.
use std::collections::BTreeMap;
use std::time::Duration;
use std::sync::atomic::{AtomicU64, Ordering};
use futures::StreamExt;
use ibapi::{Client, contracts::{Contract, ContractDetails, SecurityType}};
use ibapi::subscriptions::SubscriptionItemStreamExt;
use tokio::{sync::Mutex, time::Instant};
use crate::types::*;

#[derive(Default)]
pub(crate) struct SearchService {
    generation: AtomicU64,
    state: Mutex<SearchState>,
}

#[derive(Default)]
struct SearchState {
    last: Option<Instant>,
    cache: BTreeMap<String, InstrumentSearchResults>,
}

fn allowed(venue: &str) -> bool {
    matches!(venue, "NYSE" | "NASDAQ" | "NASDAQ.NMS" | "NASDAQ.NGS" | "NASDAQ.SCM" | "ISLAND" | "AMEX" | "ARCA" | "BATS" | "BATS.US" | "IEX" | "TSE" | "TSX" | "VENTURE" | "TSXV" | "PURE" | "CSE" | "CNSX" | "NEO" | "AEQLIT")
}
fn instrument(d: ContractDetails, has_options: bool) -> Instrument {
    let c = d.contract;
    let kind = if c.security_type == SecurityType::Stock && d.stock_type == "ETF" { "ETF".into() } else { c.security_type.to_string() };
    let venue = if c.primary_exchange.to_string().is_empty() { c.exchange.to_string() } else { c.primary_exchange.to_string() };
    Instrument { contract_id: c.contract_id, symbol: c.symbol.to_string(), local_symbol: c.local_symbol,
        name: d.long_name, kind, exchange: if c.security_type == SecurityType::Index { venue.clone() } else { "SMART".into() },
        primary_exchange: venue, currency: c.currency.to_string(), has_options }
}
pub(crate) fn contract(i: &Instrument) -> Contract {
    Contract { contract_id: i.contract_id, exchange: i.exchange.clone().into(), ..Default::default() }
}
// Catalog entries are resolved against Gateway; an unresolved index is never selectable.
const INDEXES: &[(&str, &str, &str, &str)] = &[
    ("SPX", "S&P 500", "CBOE", "USD"), ("NDX", "Nasdaq 100", "NASDAQ", "USD"),
    ("INDU", "Dow Jones Industrial Average DJI", "NYSE", "USD"), ("RUT", "Russell 2000", "RUSSELL", "USD"),
    ("VIX", "Volatility Index", "CBOE", "USD"), ("TSE", "S&P TSX Composite", "TSE", "CAD"),
    ("TSE60", "S&P TSX 60", "TSE", "CAD"),
];
async fn pace(last: &mut Option<Instant>) {
    if let Some(previous) = *last {
        tokio::time::sleep_until(previous + Duration::from_secs(1)).await;
    }
    *last = Some(Instant::now());
}

pub(crate) async fn search(client: &Client, service: &SearchService, query: &str) -> Result<InstrumentSearchResults, IbkrError> {
    let query = query.trim().to_uppercase();
    if query.is_empty() { return Ok(InstrumentSearchResults::default()); }
    let generation = service.generation.fetch_add(1, Ordering::SeqCst) + 1;
    let current = || service.generation.load(Ordering::SeqCst) == generation;
    let mut state = service.state.lock().await;
    if !current() { return Ok(InstrumentSearchResults::default()); }
    if let Some(cached) = state.cache.get(&query) { return Ok(cached.clone()); }
    pace(&mut state.last).await;
    if !current() { return Ok(InstrumentSearchResults::default()); }
    let samples = client.matching_symbols(&query).await?;
    let mut results = BTreeMap::new();
    for sample in samples {
        if !current() { return Ok(InstrumentSearchResults::default()); }
        if sample.contract.security_type != SecurityType::Stock || !allowed(&sample.contract.primary_exchange.to_string()) { continue; }
        let has_options = sample.derivative_security_types.iter().any(|s| s == "OPT");
        let details = client.contract_details(&sample.contract).await?;
        for d in details {
            let i = instrument(d, has_options);
            if allowed(&i.primary_exchange) { results.insert(i.contract_id, i); }
        }
    }
    let mut unavailable_indexes = vec![];
    for &(symbol, name, exchange, currency) in INDEXES {
        if !current() { return Ok(InstrumentSearchResults::default()); }
        if !symbol.contains(&query) && !name.to_uppercase().contains(&query) { continue; }
        let c = Contract { symbol: symbol.into(), security_type: SecurityType::Index, exchange: exchange.into(), currency: currency.into(), ..Default::default() };
        let details = match client.contract_details(&c).await {
            Ok(details) if !details.is_empty() => Ok(details),
            _ => {
                // Index venues can differ between Gateway catalogs. Ask IB to
                // qualify the symbol, then retain the returned native exchange.
                let query = Contract { exchange: "".into(), ..c };
                client.contract_details(&query).await
            }
        };
        match details {
            Ok(details) if !details.is_empty() => {
                for d in details { let i = instrument(d, true); results.insert(i.contract_id, i); }
            }
            _ => unavailable_indexes.push(format!("{name} ({symbol})")),
        }
    }
    let mut results: Vec<_> = results.into_values().collect();
    results.sort_by_key(|i| (i.symbol != query, !i.symbol.starts_with(&query), i.symbol.clone(), i.primary_exchange.clone()));
    if state.cache.len() >= 100 { state.cache.clear(); }
    let response = InstrumentSearchResults { instruments: results, unavailable_indexes };
    state.cache.insert(query, response.clone());
    Ok(response)
}
pub(crate) async fn chains(client: &Client, i: &Instrument) -> Result<Vec<SearchChain>, IbkrError> {
    let sec = if i.kind == "IND" { SecurityType::Index } else { SecurityType::Stock };
    let mut stream = client.option_chain(&i.symbol, sec, i.contract_id).subscribe().await?.filter_data();
    let mut chains = vec![];
    while let Some(item) = stream.next().await {
        let c = item?;
        let mut expirations: Vec<_> = c.expirations.into_iter().collect();
        expirations.sort();
        chains.push(SearchChain { exchange: c.exchange.to_string(), trading_class: c.trading_class, multiplier: c.multiplier, expirations });
    }
    chains.sort_by_key(|c| (c.exchange != "SMART", c.trading_class.clone(), c.exchange.clone()));
    Ok(chains)
}
pub(crate) async fn contracts(client: &Client, i: &Instrument, chain: &SearchChain, expiry: &str, call: bool) -> Result<Vec<Instrument>, IbkrError> {
    let c = option_query(i, chain, expiry, call)?;
    let mut details = client.contract_details(&c).await?;
    details.sort_by(|a,b| a.contract.strike.total_cmp(&b.contract.strike));
    Ok(details.into_iter().map(|d| { let strike = d.contract.strike; let mut result = instrument(d, false); result.exchange = chain.exchange.clone(); result.name = format!("{} {} {} {}", i.symbol, expiry, strike, if call { "Call" } else { "Put" }); result }).collect())
}

fn option_query(i: &Instrument, chain: &SearchChain, expiry: &str, call: bool) -> Result<Contract, IbkrError> {
    if !chain.expirations.iter().any(|e| e == expiry) { return Err(IbkrError::Invalid { message: "Choose a listed expiry".into() }); }
    Ok(Contract { symbol: i.symbol.clone().into(), security_type: SecurityType::Option, exchange: chain.exchange.clone().into(), currency: i.currency.clone().into(), trading_class: chain.trading_class.clone(), multiplier: chain.multiplier.clone(), last_trade_date_or_contract_month: expiry.into(), right: Some(if call { ibapi::contracts::OptionRight::Call } else { ibapi::contracts::OptionRight::Put }), ..Default::default() })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn venue_filter_uses_listing() { assert!(allowed("TSE")); assert!(allowed("ISLAND")); assert!(!allowed("SMART")); assert!(!allowed("LSE")); }
    #[test] fn routing_preserves_index_exchange() {
        let d = ContractDetails { contract: Contract { contract_id: 42, symbol: "SPX".into(), security_type: SecurityType::Index, exchange: "CBOE".into(), ..Default::default() }, ..Default::default() };
        let i = instrument(d, true); assert_eq!(contract(&i).exchange.to_string(), "CBOE"); assert_eq!(i.kind, "IND");
    }
    #[test] fn etf_is_not_relabelled_stock() {
        let d = ContractDetails { stock_type: "ETF".into(), contract: Contract::stock("SPY").build(), ..Default::default() };
        assert_eq!(instrument(d, true).kind, "ETF");
    }
    #[tokio::test(start_paused = true)]
    async fn searches_are_paced_even_after_a_fast_reply() {
        let mut last = None;
        pace(&mut last).await;
        let first = last.unwrap();
        pace(&mut last).await;
        assert!(last.unwrap().duration_since(first) >= Duration::from_secs(1));
    }

    #[test]
    fn canadian_option_query_retains_listing_and_class() {
        let d = ContractDetails { contract: Contract::stock("XIU").build(), ..Default::default() };
        let mut i = instrument(d, true);
        i.currency = "CAD".into();
        let chain = SearchChain { exchange: "CDE".into(), trading_class: "XIU1".into(), multiplier: "100".into(), expirations: vec!["20261218".into()] };
        let q = option_query(&i, &chain, "20261218", false).unwrap();
        assert_eq!(q.exchange.to_string(), "CDE");
        assert_eq!(q.currency.to_string(), "CAD");
        assert_eq!(q.trading_class, "XIU1");
        assert_eq!(q.right, Some(ibapi::contracts::OptionRight::Put));
        assert!(option_query(&i, &chain, "20270101", true).is_err());
    }

}
