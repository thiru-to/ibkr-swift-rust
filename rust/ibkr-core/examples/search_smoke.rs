//! Read-only search/contract/history check against a running paper Gateway.
//! cargo run --example search_smoke
use ibkr_core::*;
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let session = connect("127.0.0.1".into(), 4002, 73).await?;
    for query in ["AAPL", "SPY", "RY", "XIU", "SPX", "NDX", "INDU", "RUT", "VIX", "TSE60", "TSE"] {
        let response = session.search_instruments(query.into()).await?;
        println!("  unavailable indexes: {:?}", response.unavailable_indexes);
        let found = response.instruments;
        println!("{query}: {} results", found.len());
        for i in &found { println!("  {} {} {} {} #{}", i.symbol, i.kind, i.primary_exchange, i.currency, i.contract_id); }
        if let Some(i) = found.iter().find(|i| i.symbol == query && (i.primary_exchange == "TSE" || i.currency == "USD")) {
            match session.instrument_history(i.clone(), ChartRange::Day, BarInterval::Min5, None).await {
                Ok(bars) => println!("  history: {} bars", bars.len()),
                Err(e) => println!("  history unavailable: {e}"),
            }
            if ["SPY", "XIU"].contains(&query) {
                let chains = session.search_option_chains(i.clone()).await?;
                println!("  {} option chains", chains.len());
                if let Some(chain) = chains.first()
                    && let Some(expiry) = chain.expirations.first() {
                        let options = session.search_option_contracts(i.clone(), chain.clone(), expiry.clone(), true).await?;
                        println!("  {} calls for {} {}", options.len(), expiry, chain.exchange);
                        if let Some(option) = options.first() { println!("  first: {} #{}", option.name, option.contract_id); }
                }
            }
        }
    }
    session.disconnect().await?;
    Ok(())
}
