//! `IbkrSession`: the single object Swift talks to.
//!
//! All IB work runs on one crate-owned Tokio runtime. Async exports hop onto it via
//! [`run`], so the foreign executor only ever polls a `JoinHandle`. Streams run as
//! spawned tasks that push snapshots to a foreign listener; the returned
//! [`StreamHandle`] aborts the task (dropping the `ibapi` subscription cancels it on
//! the IB side).

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use futures::StreamExt;
use ibapi::accounts::types::{AccountGroup, AccountId};
use ibapi::accounts::{AccountSummaryResult, AccountSummaryTags, PositionUpdate};
use ibapi::contracts::tick_types::TickType;
use ibapi::contracts::Contract;
use ibapi::market_data::realtime::TickTypes;
use ibapi::market_data::MarketDataType;
use ibapi::subscriptions::SubscriptionItemStreamExt;
use ibapi::Client;
use tokio::runtime::Runtime;
use tokio::task::AbortHandle;

use crate::strategy::{self, StrategyHandle, StrategyListener};
use crate::types::*;
use crate::{options, orders};

const LIVE_PORTS: [u16; 2] = [4001, 7496];

fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("ibkr-core")
            .build()
            .expect("failed to build tokio runtime")
    })
}

async fn run<T, F>(fut: F) -> Result<T, IbkrError>
where
    T: Send + 'static,
    F: Future<Output = Result<T, IbkrError>> + Send + 'static,
{
    rt().spawn(fut).await.map_err(|e| IbkrError::Api { message: e.to_string() })?
}

fn invalid(message: impl Into<String>) -> IbkrError {
    IbkrError::Invalid { message: message.into() }
}

// ---------------------------------------------------------------------------
// Listener callbacks (implemented in Swift)
// ---------------------------------------------------------------------------

#[uniffi::export(with_foreign)]
pub trait PositionsListener: Send + Sync {
    fn on_positions(&self, positions: Vec<Position>);
    fn on_error(&self, message: String);
}

#[uniffi::export(with_foreign)]
pub trait QuoteListener: Send + Sync {
    fn on_quote(&self, quote: Quote);
    fn on_error(&self, message: String);
}

#[uniffi::export(with_foreign)]
pub trait OrdersListener: Send + Sync {
    fn on_orders(&self, orders: Vec<OrderInfo>);
    fn on_error(&self, message: String);
}

/// Cancels its stream when `cancel()` is called or when it is dropped.
#[derive(uniffi::Object)]
pub struct StreamHandle {
    abort: AbortHandle,
}

#[uniffi::export]
impl StreamHandle {
    pub fn cancel(&self) {
        self.abort.abort();
    }
}

impl Drop for StreamHandle {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

fn spawn_stream<F>(fut: F) -> Arc<StreamHandle>
where
    F: Future<Output = ()> + Send + 'static,
{
    Arc::new(StreamHandle { abort: rt().spawn(fut).abort_handle() })
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct IbkrSession {
    client: Arc<Client>,
    account: String,
    port: u16,
}

/// Connects to TWS / IB Gateway. Requests delayed market data as a fallback so quotes
/// work without a market-data subscription (live data is still used when available).
#[uniffi::export]
pub async fn connect(host: String, port: u16, client_id: i32) -> Result<Arc<IbkrSession>, IbkrError> {
    run(async move {
        let client = Client::connect(&format!("{host}:{port}"), client_id).await?;
        client.switch_market_data_type(MarketDataType::Delayed).await?;
        let account = client
            .managed_accounts()
            .await?
            .into_iter()
            .find(|a| !a.is_empty())
            .ok_or_else(|| invalid("no managed accounts returned"))?;
        Ok(Arc::new(IbkrSession { client: Arc::new(client), account, port }))
    })
    .await
}

#[uniffi::export]
impl IbkrSession {
    pub fn account(&self) -> String {
        self.account.clone()
    }

    /// True for the live-trading ports (Gateway 4001, TWS 7496).
    pub fn is_live(&self) -> bool {
        LIVE_PORTS.contains(&self.port)
    }

    pub async fn disconnect(&self) -> Result<(), IbkrError> {
        let client = self.client.clone();
        run(async move {
            client.disconnect().await;
            Ok(())
        })
        .await
    }

    pub async fn account_summary(&self) -> Result<AccountSummary, IbkrError> {
        let client = self.client.clone();
        let account = self.account.clone();
        run(async move { fetch_account_summary(&client, account).await }).await
    }

    pub fn subscribe_positions(&self, listener: Arc<dyn PositionsListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            if let Err(e) = stream_positions(&client, listener.as_ref()).await {
                listener.on_error(e.to_string());
            }
        })
    }

    pub fn subscribe_quote(&self, symbol: String, listener: Arc<dyn QuoteListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            let symbol = symbol.trim().to_uppercase();
            let result = if symbol.is_empty() {
                Err(invalid("symbol is required"))
            } else {
                stream_quote(&client, &Contract::stock(symbol.clone()).build(), symbol, listener.as_ref()).await
            };
            if let Err(e) = result {
                listener.on_error(e.to_string());
            }
        })
    }

    /// Quote for one option contract; `Quote.symbol` is IB's local symbol.
    pub fn subscribe_option_quote(&self, option: OptionSpec, listener: Arc<dyn QuoteListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            let result = async {
                let opt = options::resolve_option(&client, &option).await?;
                stream_quote(&client, &opt.contract, opt.local_symbol.clone(), listener.as_ref()).await
            };
            if let Err(e) = result.await {
                listener.on_error(e.to_string());
            }
        })
    }

    pub async fn option_chain(&self, symbol: String) -> Result<OptionChain, IbkrError> {
        let client = self.client.clone();
        run(async move { options::option_chain(&client, &symbol).await }).await
    }

    /// Starts a strategy task. `allow_delayed` is forced off on live sessions.
    pub fn arm_strategy(&self, mut spec: StrategySpec, listener: Arc<dyn StrategyListener>) -> Arc<StrategyHandle> {
        if self.is_live() || !self.account.starts_with('D') {
            spec.allow_delayed = false;
        }
        strategy::spawn(rt(), self.client.clone(), spec, listener)
    }

    pub fn subscribe_orders(&self, listener: Arc<dyn OrdersListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            if let Err(e) = orders::stream_orders(&client, listener.as_ref()).await {
                listener.on_error(e.to_string());
            }
        })
    }

    /// Submits an order and returns its order id. Status arrives via `subscribe_orders`.
    pub async fn place_order(&self, request: OrderRequest) -> Result<i32, IbkrError> {
        validate_order(&request)?;
        let client = self.client.clone();
        run(async move {
            let contract = Contract::stock(request.symbol.trim().to_uppercase()).build();
            let builder = client.order(&contract);
            let builder = match request.side {
                OrderSide::Buy => builder.buy(request.quantity),
                OrderSide::Sell => builder.sell(request.quantity),
            };
            let builder = match request.kind {
                OrderKind::Market => builder.market(),
                OrderKind::Limit { price } => builder.limit(price),
            };
            let builder = builder.time_in_force(match request.tif {
                TimeInForce::Day => ibapi::orders::TimeInForce::Day,
                TimeInForce::Gtc => ibapi::orders::TimeInForce::GoodTillCanceled,
            });
            Ok(builder.submit().await?.value())
        })
        .await
    }

    pub async fn cancel_order(&self, order_id: i32) -> Result<(), IbkrError> {
        let client = self.client.clone();
        run(async move {
            // Wait briefly for IB's first reply so rejections surface as errors.
            let mut sub = client.cancel_order(order_id, "").await?.filter_data();
            match tokio::time::timeout(Duration::from_secs(3), sub.next()).await {
                Ok(Some(Err(e))) => Err(e.into()),
                _ => Ok(()),
            }
        })
        .await
    }
}

fn validate_order(r: &OrderRequest) -> Result<(), IbkrError> {
    if r.symbol.trim().is_empty() {
        return Err(invalid("symbol is required"));
    }
    if !(r.quantity.is_finite() && r.quantity > 0.0) {
        return Err(invalid("quantity must be greater than 0"));
    }
    if let OrderKind::Limit { price } = r.kind
        && !(price.is_finite() && price > 0.0)
    {
        return Err(invalid("limit price must be greater than 0"));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Account summary
// ---------------------------------------------------------------------------

const SUMMARY_TAGS: &[&str] = &[
    AccountSummaryTags::NET_LIQUIDATION,
    AccountSummaryTags::TOTAL_CASH_VALUE,
    AccountSummaryTags::BUYING_POWER,
    AccountSummaryTags::AVAILABLE_FUNDS,
    AccountSummaryTags::GROSS_POSITION_VALUE,
];

async fn fetch_account_summary(client: &Client, account: String) -> Result<AccountSummary, IbkrError> {
    let mut summary = AccountSummary { account: account.clone(), ..Default::default() };

    let mut sub = client.account_summary(&AccountGroup("All".to_string()), SUMMARY_TAGS).await?.filter_data();
    while let Some(item) = sub.next().await {
        match item? {
            AccountSummaryResult::Summary(s) if s.account == account => {
                let value = s.value.parse::<f64>().ok();
                match s.tag.as_str() {
                    AccountSummaryTags::NET_LIQUIDATION => {
                        summary.net_liquidation = value;
                        summary.currency = s.currency;
                    }
                    AccountSummaryTags::TOTAL_CASH_VALUE => summary.total_cash = value,
                    AccountSummaryTags::BUYING_POWER => summary.buying_power = value,
                    AccountSummaryTags::AVAILABLE_FUNDS => summary.available_funds = value,
                    AccountSummaryTags::GROSS_POSITION_VALUE => summary.gross_position_value = value,
                    _ => {}
                }
            }
            AccountSummaryResult::Summary(_) => {}
            AccountSummaryResult::End => break,
        }
    }
    drop(sub);

    // P&L is a stream; take the first update, but don't let it block the summary.
    if let Ok(pnl) = client.pnl(&AccountId(account), None).await {
        let mut pnl = pnl.filter_data();
        if let Ok(Some(Ok(p))) = tokio::time::timeout(Duration::from_secs(2), pnl.next()).await {
            summary.daily_pnl = Some(p.daily_pnl);
            summary.unrealized_pnl = p.unrealized_pnl;
            summary.realized_pnl = p.realized_pnl;
        }
    }

    Ok(summary)
}

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------

async fn stream_positions(client: &Client, listener: &dyn PositionsListener) -> Result<(), IbkrError> {
    let mut sub = client.positions().await?.filter_data();
    let mut book: BTreeMap<(String, i32), Position> = BTreeMap::new();
    let mut ready = false;

    while let Some(item) = sub.next().await {
        match item? {
            PositionUpdate::Position(p) => {
                let key = (p.account.clone(), p.contract.contract_id);
                if p.position == 0.0 {
                    book.remove(&key);
                } else {
                    book.insert(
                        key,
                        Position {
                            account: p.account,
                            contract_id: p.contract.contract_id,
                            symbol: p.contract.symbol.to_string(),
                            sec_type: p.contract.security_type.to_string(),
                            local_symbol: p.contract.local_symbol,
                            currency: p.contract.currency.to_string(),
                            quantity: p.position,
                            average_cost: p.average_cost,
                        },
                    );
                }
            }
            PositionUpdate::PositionEnd => ready = true,
        }
        if ready {
            let mut positions: Vec<Position> = book.values().cloned().collect();
            positions.sort_by(|a, b| a.symbol.cmp(&b.symbol));
            listener.on_positions(positions);
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Quotes
// ---------------------------------------------------------------------------

async fn stream_quote(client: &Client, contract: &Contract, symbol: String, listener: &dyn QuoteListener) -> Result<(), IbkrError> {
    let mut sub = client.market_data(contract).subscribe().await?.filter_data();
    let mut quote = Quote { symbol, ..Default::default() };

    while let Some(item) = sub.next().await {
        let changed = match item? {
            TickTypes::Price(t) => apply_price(&mut quote, t.tick_type, t.price),
            TickTypes::Size(t) => apply_size(&mut quote, t.tick_type, t.size),
            TickTypes::PriceSize(t) => {
                let a = apply_price(&mut quote, t.price_tick_type, t.price);
                let b = apply_size(&mut quote, t.size_tick_type, t.size);
                a || b
            }
            TickTypes::MarketDataType(t) => {
                let delayed = matches!(t, MarketDataType::Delayed | MarketDataType::DelayedFrozen);
                std::mem::replace(&mut quote.delayed, delayed) != delayed
            }
            _ => false,
        };
        if changed {
            listener.on_quote(quote.clone());
        }
    }
    Ok(())
}

/// IB sends -1 for "no value". Returns whether the slot changed.
fn set(slot: &mut Option<f64>, v: f64) -> bool {
    let v = (v.is_finite() && v >= 0.0).then_some(v);
    std::mem::replace(slot, v) != v
}

fn apply_price(q: &mut Quote, tick: TickType, price: f64) -> bool {
    let slot = match tick {
        TickType::Bid | TickType::DelayedBid => &mut q.bid,
        TickType::Ask | TickType::DelayedAsk => &mut q.ask,
        TickType::Last | TickType::DelayedLast => &mut q.last,
        TickType::Close | TickType::DelayedClose => &mut q.close,
        _ => return false,
    };
    set(slot, price)
}

fn apply_size(q: &mut Quote, tick: TickType, size: f64) -> bool {
    let slot = match tick {
        TickType::BidSize | TickType::DelayedBidSize => &mut q.bid_size,
        TickType::AskSize | TickType::DelayedAskSize => &mut q.ask_size,
        TickType::Volume | TickType::DelayedVolume => &mut q.volume,
        _ => return false,
    };
    set(slot, size)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(qty: f64, kind: OrderKind) -> OrderRequest {
        OrderRequest { symbol: "AAPL".into(), side: OrderSide::Buy, quantity: qty, kind, tif: TimeInForce::Day }
    }

    #[test]
    fn validates_orders() {
        assert!(validate_order(&req(1.0, OrderKind::Market)).is_ok());
        assert!(validate_order(&req(0.0, OrderKind::Market)).is_err());
        assert!(validate_order(&req(1.0, OrderKind::Limit { price: 0.0 })).is_err());
        assert!(validate_order(&OrderRequest { symbol: " ".into(), ..req(1.0, OrderKind::Market) }).is_err());
    }

    #[test]
    fn coalesces_ticks() {
        let mut q = Quote::default();
        assert!(apply_price(&mut q, TickType::DelayedBid, 10.5));
        assert!(!apply_price(&mut q, TickType::DelayedBid, 10.5), "unchanged value is not a change");
        assert!(!apply_price(&mut q, TickType::Ask, -1.0), "-1 means no value");
        assert!(apply_size(&mut q, TickType::Volume, 1000.0));
        assert!(!apply_price(&mut q, TickType::High, 11.0));
        assert_eq!(q.bid, Some(10.5));
        assert_eq!(q.ask, None);
        assert_eq!(q.volume, Some(1000.0));
    }
}
