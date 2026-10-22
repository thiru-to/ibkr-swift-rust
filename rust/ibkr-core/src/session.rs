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
use ibapi::market_data::historical::{Bar, BarSize, BarTimestamp, Duration as HistoryDuration};
use ibapi::market_data::realtime::TickTypes;
use ibapi::market_data::MarketDataType;
use ibapi::orders::PlaceOrder;
use ibapi::subscriptions::{Subscription, SubscriptionItem, SubscriptionItemStreamExt};
use ibapi::{Client, TRANSPORT_RECONNECT_CODE};
use time::OffsetDateTime;
use tokio::runtime::Runtime;
use tokio::task::AbortHandle;

use crate::position::{self, Ctx};
use crate::risk::{RiskGuard, RiskListener};
use crate::strategy::{self, OwnedOrders, StrategyHandle, StrategyListener};
use crate::types::*;
use crate::{options, orders};

const LIVE_PORTS: [u16; 2] = [4001, 7496];
/// How long `place_order` waits for IB's first answer before reporting "Sent".
const ACK_WAIT: Duration = Duration::from_secs(5);

pub(crate) fn rt() -> &'static Runtime {
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

#[uniffi::export(with_foreign)]
pub trait ConnectionListener: Send + Sync {
    fn on_link(&self, status: LinkStatus, message: String);
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
    client_id: i32,
    /// Orders that running strategies placed; manual position actions leave them alone.
    strategy_orders: OwnedOrders,
    risk: Arc<RiskGuard>,
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
        let client = Arc::new(client);
        let strategy_orders = OwnedOrders::default();
        let live = LIVE_PORTS.contains(&port) || !account.starts_with('D');
        let risk = RiskGuard::new(client.clone(), client_id, strategy_orders.clone(), live);
        Ok(Arc::new(IbkrSession { client, account, port, client_id, strategy_orders, risk }))
    })
    .await
}

#[uniffi::export]
impl IbkrSession {
    pub fn account(&self) -> String {
        self.account.clone()
    }

    /// This connection's API client id. Order ids are only unique per client id.
    pub fn client_id(&self) -> i32 {
        self.client_id
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

    /// Reports the Gateway link going down and coming back. ibapi reconnects by itself;
    /// the orders and positions streams resubscribe on their own, quotes must be
    /// re-requested on `RestoredDataLost`.
    pub fn subscribe_connection(&self, listener: Arc<dyn ConnectionListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move { watch_link(&client, listener.as_ref()).await })
    }

    pub fn subscribe_positions(&self, listener: Arc<dyn PositionsListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            let on_error = |e: String| listener.on_error(format!("Positions: {e}"));
            keep_streaming(&client, on_error, || stream_positions(&client, listener.as_ref())).await
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

    /// Trade bars for a stock over `range`, regular hours only. With `end` (unix seconds,
    /// e.g. the oldest bar already shown) it returns the `range` of bars before it, for
    /// paging back in time; otherwise the `range` up to now.
    pub async fn price_history(
        &self,
        symbol: String,
        range: ChartRange,
        interval: BarInterval,
        end: Option<i64>,
    ) -> Result<Vec<PriceBar>, IbkrError> {
        let client = self.client.clone();
        run(async move {
            let symbol = symbol.trim().to_uppercase();
            if symbol.is_empty() {
                return Err(invalid("symbol is required"));
            }
            let contract = Contract::stock(symbol).build();
            let mut request = client.historical_data(&contract, bar_size(interval)).duration(history_duration(range));
            if let Some(end) = end {
                let end = OffsetDateTime::from_unix_timestamp(end).map_err(|e| invalid(e.to_string()))?;
                request = request.ending(end);
            }
            let data = request.fetch().await?;
            let bars = data.bars.iter().map(price_bar);
            // IB can include the bar that `end` falls in (e.g. that whole day); the caller has it.
            Ok(bars.filter(|b| end.is_none_or(|end| b.time < end)).collect())
        })
        .await
    }

    /// Starts a strategy task. `allow_delayed` is forced off on live sessions.
    pub fn arm_strategy(&self, mut spec: StrategySpec, listener: Arc<dyn StrategyListener>) -> Arc<StrategyHandle> {
        if self.is_live() || !self.account.starts_with('D') {
            spec.allow_delayed = false;
        }
        strategy::spawn(rt(), self.client.clone(), spec, listener, self.strategy_orders.clone(), self.risk.clone())
    }

    /// Starts the risk guard: loads the account's saved limits and halt from `state_path`,
    /// then tracks IB's daily P&L. Cancelling the handle stops it (live sessions then refuse
    /// entries). See `risk.rs`.
    pub fn start_risk(&self, state_path: String, listener: Arc<dyn RiskListener>) -> Arc<StreamHandle> {
        let (client, account, risk) = (self.client.clone(), self.account.clone(), self.risk.clone());
        risk.start(state_path.into(), listener.clone());
        spawn_stream(async move {
            /// Marks the guard stopped however the task ends (including abort).
            struct Stopped(Arc<RiskGuard>);
            impl Drop for Stopped {
                fn drop(&mut self) {
                    self.0.stop();
                }
            }
            let _stopped = Stopped(risk.clone());
            let on_error = |e: String| listener.on_error(format!("Daily P&L: {e}"));
            let pnl = keep_streaming(&client, on_error, || stream_pnl(&client, &account, &risk));
            let roll = async {
                loop {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    risk.tick();
                }
            };
            tokio::join!(pnl, roll);
        })
    }

    pub fn risk_status(&self) -> RiskStatus {
        self.risk.status()
    }

    /// Tighter limits apply now; looser ones from the next trading day.
    pub fn set_risk_limits(&self, limits: RiskLimits) -> Result<RiskStatus, IbkrError> {
        self.risk.set_limits(limits)
    }

    /// Kill switch: no opening orders for the rest of the trading day. Disarms strategies
    /// that haven't bought, cancels entries in flight and this client's manual buys. Exits
    /// stay at IB.
    pub fn halt_trading(&self, reason: String) {
        self.risk.halt(reason);
    }

    /// Quote for any contract by IB contract id (a position's); `Quote.symbol` is IB's local symbol.
    pub fn subscribe_contract_quote(&self, contract_id: i32, listener: Arc<dyn QuoteListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        spawn_stream(async move {
            let result = async {
                let c = options::resolve_contract_id(&client, contract_id).await?;
                stream_quote(&client, &c.contract, c.local_symbol.clone(), listener.as_ref()).await
            };
            if let Err(e) = result.await {
                listener.on_error(e.to_string());
            }
        })
    }

    /// Closes a whole position with a limit order at `limit_price` (the capped price the
    /// user reviewed). Cancels this connection's working orders on the contract first and
    /// refuses positions a running strategy manages. See `position.rs`.
    pub async fn close_position(&self, contract_id: i32, expected_quantity: f64, limit_price: f64) -> Result<PlacedOrder, IbkrError> {
        let (client, account, owned, client_id) = self.parts();
        run(async move {
            let ctx = Ctx { client: &client, account: &account, client_id, owned: &owned };
            position::close(ctx, contract_id, expected_quantity, limit_price).await
        })
        .await
    }

    /// Attaches a take-profit and/or stop (one OCA group, GTC) to a position with no working orders.
    pub async fn protect_position(
        &self,
        contract_id: i32,
        expected_quantity: f64,
        take_profit: Option<f64>,
        stop: Option<f64>,
        stop_limit: Option<f64>,
    ) -> Result<Vec<PlacedOrder>, IbkrError> {
        let (client, account, owned, client_id) = self.parts();
        run(async move {
            let ctx = Ctx { client: &client, account: &account, client_id, owned: &owned };
            position::protect(ctx, contract_id, expected_quantity, take_profit, stop, stop_limit).await
        })
        .await
    }

    /// Changes the limit and/or stop price of a working order this connection placed.
    pub async fn modify_order(&self, order_id: i32, limit_price: Option<f64>, stop_price: Option<f64>) -> Result<PlacedOrder, IbkrError> {
        let (client, account, owned, client_id) = self.parts();
        run(async move {
            let ctx = Ctx { client: &client, account: &account, client_id, owned: &owned };
            position::modify(ctx, order_id, limit_price, stop_price).await
        })
        .await
    }

    pub fn subscribe_orders(&self, listener: Arc<dyn OrdersListener>) -> Arc<StreamHandle> {
        let client = self.client.clone();
        let client_id = self.client_id;
        spawn_stream(async move {
            let on_error = |e: String| listener.on_error(format!("Orders: {e}"));
            keep_streaming(&client, on_error, || orders::stream_orders(&client, listener.as_ref(), client_id)).await
        })
    }

    /// Places an order and waits briefly for IB's first answer, so a rejection comes back
    /// as an error instead of an order that never shows up. Later status arrives via
    /// `subscribe_orders`.
    pub async fn place_order(&self, request: OrderRequest) -> Result<PlacedOrder, IbkrError> {
        validate_order(&request)?;
        let (client, account, risk) = (self.client.clone(), self.account.clone(), self.risk.clone());
        run(async move {
            let symbol = request.symbol.trim().to_uppercase();
            let contract = Contract::stock(symbol.clone()).build();
            match request.side {
                OrderSide::Buy => {
                    let price = match request.kind {
                        OrderKind::Limit { price } => Some(price),
                        OrderKind::Market if risk.checks_cost() => snapshot_ask(&client, &contract).await,
                        OrderKind::Market => None,
                    };
                    risk.check_entry(price.map(|p| p * request.quantity))?;
                }
                // While halted, a sell may close a long but not open a short.
                OrderSide::Sell if risk.halted().is_some() => {
                    let held = position::stock_position(&client, &account, &symbol).await?;
                    if request.quantity > held {
                        return Err(invalid(format!(
                            "Trading is halted for today; sells are limited to the {held} {symbol} shares you hold."
                        )));
                    }
                }
                OrderSide::Sell => {}
            }
            let builder = client.order(&contract);
            let builder = match request.side {
                OrderSide::Buy => builder.buy(request.quantity),
                OrderSide::Sell => builder.sell(request.quantity),
            };
            let builder = match request.kind {
                OrderKind::Market => builder.market(),
                OrderKind::Limit { price } => builder.limit(price),
            };
            let order = builder
                .time_in_force(match request.tif {
                    TimeInForce::Day => ibapi::orders::TimeInForce::Day,
                    TimeInForce::Gtc => ibapi::orders::TimeInForce::GoodTillCanceled,
                })
                .build()
                .map_err(|e| invalid(e.to_string()))?;
            let order_id = client.next_order_id();
            // Dropping this subscription later does not cancel the order (PlaceOrder has no cancel message).
            let sub = client.place_order(order_id, &contract, &order).await?;
            await_ack(order_id, sub).await
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

/// IB answers a new order with OpenOrder / OrderStatus, or with an error (a rejection).
/// Warnings such as 399 ("won't be placed until the market opens") arrive as notices first.
pub(crate) async fn await_ack(order_id: i32, mut sub: Subscription<PlaceOrder>) -> Result<PlacedOrder, IbkrError> {
    let mut warnings: Vec<String> = Vec::new();
    let answer = tokio::time::timeout(ACK_WAIT, async {
        while let Some(item) = sub.next().await {
            let status = match item {
                Ok(SubscriptionItem::Notice(n)) => {
                    warnings.push(n.message);
                    continue;
                }
                Ok(SubscriptionItem::Data(PlaceOrder::OrderStatus(s))) => s.status,
                Ok(SubscriptionItem::Data(PlaceOrder::OpenOrder(d))) => d.order_state.status,
                Ok(SubscriptionItem::Data(_)) => continue,
                Err(ibapi::Error::Notice(n)) => return Err(format!("Order #{order_id} rejected: {}", n.message)),
                Err(e) => return Err(no_answer(order_id, e)),
            };
            return match orders::group(&status) {
                OrderStatusGroup::Cancelled | OrderStatusGroup::Inactive => {
                    let why = if warnings.is_empty() { String::new() } else { format!(": {}", warnings.join("; ")) };
                    Err(format!("Order #{order_id} {}{why}", status.as_str()))
                }
                _ => Ok(status.as_str().to_string()),
            };
        }
        Err(no_answer(order_id, "the order stream closed"))
    })
    .await;

    let status = match answer {
        Ok(Ok(status)) => status,
        Ok(Err(message)) => return Err(IbkrError::Api { message }),
        // No answer yet is not a rejection: the order may well be working.
        Err(_) => "Sent".to_string(),
    };
    Ok(PlacedOrder { order_id, status, message: warnings.join("; ") })
}

/// Not a rejection: the order reached the socket, so it may be working at IB.
fn no_answer(order_id: i32, e: impl std::fmt::Display) -> String {
    format!("Order #{order_id}: no answer from IB ({e}). It may still be working; check the Orders list before retrying.")
}

impl IbkrSession {
    fn parts(&self) -> (Arc<Client>, String, OwnedOrders, i32) {
        (self.client.clone(), self.account.clone(), self.strategy_orders.clone(), self.client_id)
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
// Connection health
// ---------------------------------------------------------------------------

/// Runs `body` again after it fails, once the client is connected. ibapi reconnects on
/// its own but fails every live subscription, so without this the order list and
/// positions would freeze silently after a Gateway blip. Errors caused by the
/// connection dropping aren't reported; `watch_link` covers those.
async fn keep_streaming<F, Fut>(client: &Client, on_error: impl Fn(String), mut body: F)
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<(), IbkrError>>,
{
    let mut backoff = Duration::from_secs(1);
    loop {
        let started = tokio::time::Instant::now();
        let result = body().await;
        if let Err(e) = result
            && client.is_connected()
        {
            on_error(e.to_string());
        }
        while !client.is_connected() {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        // Back off if the stream keeps failing straight away.
        backoff = if started.elapsed() > Duration::from_secs(30) { Duration::from_secs(1) } else { (backoff * 2).min(Duration::from_secs(30)) };
        tokio::time::sleep(backoff).await;
    }
}

/// Socket drops show up only as `is_connected()` going false (ibapi announces the
/// reconnect, not the loss); Gateway's own link to IB arrives as 1100/1101/1102 notices.
async fn watch_link(client: &Client, listener: &dyn ConnectionListener) {
    let Ok(mut notices) = client.notice_stream() else { return };
    let mut socket_up = true;
    let mut poll = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            notice = notices.next() => {
                let Some(n) = notice else {
                    return listener.on_link(LinkStatus::Lost, "The connection to IB Gateway closed. Disconnect and connect again.".into());
                };
                match n.code {
                    1100 => listener.on_link(LinkStatus::Lost, n.message),
                    1101 => listener.on_link(LinkStatus::RestoredDataLost, n.message),
                    1102 => listener.on_link(LinkStatus::Restored, n.message),
                    TRANSPORT_RECONNECT_CODE => {
                        socket_up = true;
                        listener.on_link(LinkStatus::RestoredDataLost, "Reconnected to IB Gateway".into());
                    }
                    _ => {}
                }
            }
            _ = poll.tick() => {
                let up = client.is_connected();
                if socket_up && !up {
                    listener.on_link(LinkStatus::Lost, "Lost the connection to IB Gateway; reconnecting…".into());
                }
                socket_up = up;
            }
        }
    }
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
                            multiplier: p.contract.multiplier.parse().unwrap_or(1.0),
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

/// The first ask IB reports for `contract`, waiting up to 3s; None if there's none.
pub(crate) async fn snapshot_ask(client: &Client, contract: &Contract) -> Option<f64> {
    let mut sub = client.market_data(contract).subscribe().await.ok()?.filter_data();
    let first = async {
        while let Some(Ok(tick)) = sub.next().await {
            if let Some(ask) = ask_of(&tick) {
                return Some(ask);
            }
        }
        None
    };
    tokio::time::timeout(Duration::from_secs(3), first).await.ok().flatten()
}

/// The ask in a tick, if it carries one (live or delayed).
pub(crate) fn ask_of(tick: &TickTypes) -> Option<f64> {
    let (kind, price) = match tick {
        TickTypes::Price(t) => (&t.tick_type, t.price),
        TickTypes::PriceSize(t) => (&t.price_tick_type, t.price),
        _ => return None,
    };
    (matches!(kind, TickType::Ask | TickType::DelayedAsk) && price.is_finite() && price > 0.0).then_some(price)
}

// ---------------------------------------------------------------------------
// Daily P&L (risk guard)
// ---------------------------------------------------------------------------

async fn stream_pnl(client: &Client, account: &str, risk: &RiskGuard) -> Result<(), IbkrError> {
    let result = async {
        let mut sub = client.pnl(&AccountId(account.to_string()), None).await?.filter_data();
        while let Some(item) = sub.next().await {
            // IB sends Double.MAX for "no value".
            let daily = item?.daily_pnl;
            risk.set_pnl((daily.is_finite() && daily.abs() < 1e12).then_some(daily));
        }
        Ok::<(), IbkrError>(())
    }
    .await;
    // No reading is current until the stream is back.
    risk.set_pnl(None);
    result
}

// ---------------------------------------------------------------------------
// Price history
// ---------------------------------------------------------------------------

fn history_duration(range: ChartRange) -> HistoryDuration {
    match range {
        ChartRange::Day => HistoryDuration::days(1),
        ChartRange::Week => HistoryDuration::weeks(1),
        ChartRange::Month => HistoryDuration::months(1),
        ChartRange::Year => HistoryDuration::years(1),
    }
}

fn bar_size(interval: BarInterval) -> BarSize {
    match interval {
        BarInterval::Min1 => BarSize::Min,
        BarInterval::Min2 => BarSize::Min2,
        BarInterval::Min5 => BarSize::Min5,
        BarInterval::Min15 => BarSize::Min15,
        BarInterval::Hour1 => BarSize::Hour,
        BarInterval::Hour4 => BarSize::Hour4,
        BarInterval::Day1 => BarSize::Day,
    }
}

/// Daily bars are stamped at noon UTC, so they land on the same calendar day in any
/// timezone within ±11h of UTC (midnight UTC is the previous evening in the US).
const NOON: i64 = 12 * 3600;

fn price_bar(b: &Bar) -> PriceBar {
    let time = match b.date {
        BarTimestamp::Date(d) => d.midnight().assume_utc().unix_timestamp() + NOON,
        BarTimestamp::DateTime(dt) => dt.unix_timestamp(),
    };
    PriceBar { time, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume.max(0.0) }
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

    #[test]
    fn maps_history_windows_and_bars() {
        assert_eq!(history_duration(ChartRange::Day), HistoryDuration::days(1));
        assert_eq!(history_duration(ChartRange::Year), HistoryDuration::years(1));
        assert_eq!(bar_size(BarInterval::Min1), BarSize::Min);
        assert_eq!(bar_size(BarInterval::Hour4), BarSize::Hour4);

        let day: BarTimestamp = "20240102".parse().unwrap();
        let intraday: BarTimestamp = "1704205800".parse().unwrap();
        let bar = |date| Bar { date, open: 1.0, high: 2.0, low: 0.5, close: 1.5, volume: -1.0, wap: 0.0, count: 0 };
        assert_eq!(price_bar(&bar(day)).time, 1704153600 + NOON);
        assert_eq!(price_bar(&bar(intraday)).time, 1704205800);
        assert_eq!(price_bar(&bar(day)).volume, 0.0, "-1 means no volume");
    }
}
