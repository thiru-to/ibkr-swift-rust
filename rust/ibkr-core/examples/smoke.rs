//! Read-only smoke test against a running Gateway. Never places orders.
//!
//! cargo run --example smoke -- [port] [symbol]     (defaults: 4002 AAPL; pass 4001 for live)

use std::sync::{Arc, mpsc};
use std::time::Duration;

use ibkr_core::*;

struct Positions(mpsc::Sender<Vec<Position>>);
impl PositionsListener for Positions {
    fn on_positions(&self, p: Vec<Position>) {
        let _ = self.0.send(p);
    }
    fn on_error(&self, m: String) {
        eprintln!("positions error: {m}");
    }
}

struct Quotes;
impl QuoteListener for Quotes {
    fn on_quote(&self, q: Quote) {
        println!("quote: {q:?}");
    }
    fn on_error(&self, m: String) {
        eprintln!("quote error: {m}");
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let port: u16 = args.next().map_or(Ok(4002), |p| p.parse())?;
    let symbol = args.next().unwrap_or_else(|| "AAPL".into());

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    let session = rt.block_on(connect("127.0.0.1".into(), port, 901))?;
    println!("connected: account={} live={}", session.account(), session.is_live());

    println!("summary: {:#?}", rt.block_on(session.account_summary())?);

    let (tx, rx) = mpsc::channel();
    let _positions = session.subscribe_positions(Arc::new(Positions(tx)));
    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(p) => p.iter().for_each(|p| println!("position: {p:?}")),
        Err(_) => println!("no positions snapshot within 5s"),
    }

    for (range, interval) in [(ChartRange::Day, BarInterval::Min1), (ChartRange::Week, BarInterval::Hour4), (ChartRange::Year, BarInterval::Day1)] {
        match rt.block_on(session.price_history(symbol.clone(), range, interval, None)) {
            Ok(bars) => {
                println!("history {range:?}/{interval:?}: {} bars, last {:?}", bars.len(), bars.last());
                // The page before it, as the chart loads when panning back.
                let end = bars.first().map(|b| b.time);
                match rt.block_on(session.price_history(symbol.clone(), range, interval, end)) {
                    Ok(older) => println!("  older page: {} bars, {:?} .. {:?}", older.len(), older.first().map(|b| b.time), older.last().map(|b| b.time)),
                    Err(e) => eprintln!("  older page error: {e}"),
                }
            }
            Err(e) => eprintln!("history {range:?}/{interval:?} error: {e}"),
        }
    }

    let _quote = session.subscribe_quote(symbol, Arc::new(Quotes));
    std::thread::sleep(Duration::from_secs(5));

    rt.block_on(session.disconnect())?;
    Ok(())
}
