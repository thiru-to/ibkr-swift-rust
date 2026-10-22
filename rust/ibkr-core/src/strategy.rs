//! Trigger → market entry → OCA-protected exits, one Tokio task per strategy.
//!
//! Safety invariants (see CLAUDE.md):
//! - The trigger never fires on delayed data unless `allow_delayed` (forced off on live).
//! - The trigger must be *crossed* after arming: the first last-trade tick is a baseline,
//!   and arming fails if the baseline is already through the trigger.
//! - The entry is sent at most once (the task only moves forward), and only after the risk
//!   guard approves it at that moment (halt, daily loss, cost at the current ask). A halt
//!   disarms a strategy that hasn't bought and cancels an entry in flight; exits are never
//!   blocked.
//! - Every sell-to-close (take-profit, stop, EOD close, close-now) shares one OCA group with
//!   ReduceWithBlock: a fill on one shrinks the others by the same amount, so together they
//!   never sell more than the position and none can open a short.
//! - Orders are tracked through ibapi's per-order status taps, not their `place_order`
//!   subscriptions: a cancel or modify sent from elsewhere re-registers the order id and
//!   would silently take a subscription's messages.

use std::collections::HashSet;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures::stream::{SelectAll, Stream, StreamExt};
use ibapi::Client;
use ibapi::contracts::tick_types::TickType;
use ibapi::market_data::MarketDataType;
use ibapi::market_data::realtime::TickTypes;
use ibapi::orders::conditions::TimeCondition;
use ibapi::orders::{Action, OcaType, Order, OrderCondition, OrderStatus, OrderStatusKind, order_builder};
use ibapi::subscriptions::SubscriptionItemStreamExt;
use jiff::Zoned;
use jiff::civil::Time;
use jiff::tz::TimeZone;
use tokio::sync::{mpsc, watch};

use crate::options::{self, ResolvedContract, Round};
use crate::risk::RiskGuard;
use crate::session::{ask_of, snapshot_ask};
use crate::types::*;

#[uniffi::export(with_foreign)]
pub trait StrategyListener: Send + Sync {
    fn on_update(&self, update: StrategyUpdate);
}

enum Cmd {
    Disarm,
    CloseNow,
}

/// Controls a running strategy. Dropping it before the trigger fires disarms the strategy;
/// after entry, exits stay with IB and the task keeps tracking them.
#[derive(uniffi::Object)]
pub struct StrategyHandle {
    id: u64,
    cmds: mpsc::UnboundedSender<Cmd>,
}

#[uniffi::export]
impl StrategyHandle {
    pub fn id(&self) -> u64 {
        self.id
    }

    /// Before the trigger: stop watching. While entering: cancel the entry order (any
    /// partial fill is still protected). After entry: no effect; use `close_now`.
    pub fn disarm(&self) {
        let _ = self.cmds.send(Cmd::Disarm);
    }

    /// Market-sell the filled quantity inside the strategy's OCA group.
    pub fn close_now(&self) {
        let _ = self.cmds.send(Cmd::CloseNow);
    }
}

/// Order ids that running strategies placed. Closing or protecting a position by hand
/// must not touch these (it would break the strategy's OCA group).
pub(crate) type OwnedOrders = Arc<Mutex<HashSet<i32>>>;

pub(crate) fn spawn(
    runtime: &tokio::runtime::Runtime,
    client: Arc<Client>,
    spec: StrategySpec,
    listener: Arc<dyn StrategyListener>,
    owned: OwnedOrders,
    risk: Arc<RiskGuard>,
) -> Arc<StrategyHandle> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::unbounded_channel();
    runtime.spawn(run(client, id, spec, listener, rx, owned, risk));
    Arc::new(StrategyHandle { id, cmds: tx })
}

// ---------------------------------------------------------------------------
// Pure logic (unit tested)
// ---------------------------------------------------------------------------

pub(crate) fn trigger_hit(trigger: &Trigger, last: f64) -> bool {
    match trigger.direction {
        TriggerDirection::RisesTo => last >= trigger.price,
        TriggerDirection::FallsTo => last <= trigger.price,
    }
}

pub(crate) struct EodClose {
    /// IB TimeCondition format.
    pub condition: String,
    pub deadline: jiff::Timestamp,
}

pub(crate) fn eastern() -> TimeZone {
    TimeZone::get("America/New_York").expect("bundled tzdb has America/New_York")
}

/// Finite and > 0 (also rejects NaN).
fn positive(v: f64) -> bool {
    v.is_finite() && v > 0.0
}

pub(crate) fn validate_spec(spec: &StrategySpec, now_et: &Zoned) -> Result<Option<EodClose>, IbkrError> {
    let invalid = |m: String| Err(IbkrError::Invalid { message: m });
    if !(spec.quantity >= 1.0 && spec.quantity.fract() == 0.0) {
        return invalid("quantity must be a whole number of contracts".into());
    }
    if !positive(spec.option.strike) {
        return invalid("strike must be greater than 0".into());
    }
    options::parse_expiry(&spec.option.expiry)?;
    if spec.option.expiry < now_et.strftime("%Y%m%d").to_string() {
        return invalid(format!("expiry {} is in the past", spec.option.expiry));
    }
    if let Some(t) = &spec.trigger {
        if t.underlying.trim().is_empty() {
            return invalid("trigger underlying is required".into());
        }
        if !positive(t.price) {
            return invalid("trigger price must be greater than 0".into());
        }
    }
    if let Some(Target::Percent { value } | Target::Dollars { value }) = spec.take_profit
        && !positive(value)
    {
        return invalid("take-profit must be greater than 0".into());
    }
    if let Some(sl) = spec.stop_loss {
        match sl.target {
            Target::Percent { value } if !(positive(value) && value < 100.0) => {
                return invalid("stop-loss % must be between 0 and 100".into());
            }
            Target::Dollars { value } if !positive(value) => return invalid("stop-loss $ must be greater than 0".into()),
            _ => {}
        }
        if let StopKind::StopLimit { limit_offset } = sl.kind
            && !(limit_offset.is_finite() && limit_offset >= 0.0)
        {
            return invalid("stop-limit offset must be 0 or more".into());
        }
    }

    let Some(hhmm) = spec.eod_close.as_deref() else { return Ok(None) };
    let time = Time::strptime("%H:%M", hhmm.trim())
        .map_err(|_| IbkrError::Invalid { message: format!("close time must be HH:MM, got {hhmm:?}") })?;
    if time >= Time::constant(16, 0, 0, 0) {
        return invalid("close time must be before 16:00 ET".into());
    }
    let at = now_et
        .date()
        .to_datetime(time)
        .to_zoned(now_et.time_zone().clone())
        .map_err(|e| IbkrError::Invalid { message: e.to_string() })?;
    if at.timestamp() <= now_et.timestamp() + jiff::SignedDuration::from_secs(30) {
        return invalid(format!("close time {hhmm} ET has already passed today"));
    }
    Ok(Some(EodClose { condition: at.strftime("%Y%m%d %H:%M:%S US/Eastern").to_string(), deadline: at.timestamp() }))
}

/// IB keeps OCA group names for the whole account and day: reusing one that already
/// filled gets every member rejected ("OCA group is already filled"). Order ids and
/// strategy ids restart per connection, so the name includes a nanosecond timestamp.
pub(crate) fn oca_group_name(entry_order_id: i32) -> String {
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = jiff::Timestamp::now().as_nanosecond() as u64;
    // Strictly increasing even if two calls land in the same nanosecond.
    let prev = LAST.try_update(Ordering::Relaxed, Ordering::Relaxed, |p| Some(p.max(now) + 1)).unwrap_or(0);
    let stamp = prev.max(now) + 1;
    format!("ibkr-swift-{stamp}-{entry_order_id}")
}

#[derive(Debug, Default, PartialEq)]
pub(crate) struct ExitPlan {
    pub take_profit: Option<f64>,
    pub stop: Option<f64>,
    pub stop_limit: Option<f64>,
}

/// Exit prices from the actual average fill. `$` targets are for the whole position.
pub(crate) fn plan_exits(
    fill: f64,
    quantity: f64,
    multiplier: f64,
    take_profit: Option<Target>,
    stop_loss: Option<StopSpec>,
    increments: &[(f64, f64)],
) -> Result<ExitPlan, String> {
    let per_contract = |dollars: f64| dollars / (quantity * multiplier);
    let mut plan = ExitPlan::default();

    if let Some(tp) = take_profit {
        let raw = match tp {
            Target::Percent { value } => fill * (1.0 + value / 100.0),
            Target::Dollars { value } => fill + per_contract(value),
        };
        let price = options::round_to_tick(raw, increments, Round::Up);
        if price <= fill {
            return Err(format!("take-profit {price} is not above the fill {fill}"));
        }
        plan.take_profit = Some(price);
    }

    if let Some(sl) = stop_loss {
        let raw = match sl.target {
            Target::Percent { value } => fill * (1.0 - value / 100.0),
            Target::Dollars { value } => fill - per_contract(value),
        };
        let min = options::tick_at(0.0, increments);
        let stop = options::round_to_tick(raw, increments, Round::Down).max(min);
        if stop >= fill {
            return Err(format!("stop {stop} is not below the fill {fill}"));
        }
        plan.stop = Some(stop);
        if let StopKind::StopLimit { limit_offset } = sl.kind {
            plan.stop_limit = Some(options::round_to_tick(stop - limit_offset, increments, Round::Down).max(min));
        }
    }
    Ok(plan)
}

// ---------------------------------------------------------------------------
// Task
// ---------------------------------------------------------------------------

struct Tracker {
    u: StrategyUpdate,
    listener: Arc<dyn StrategyListener>,
    /// IB refused the time-conditioned EOD order, so the app sends it.
    eod_by_app: bool,
    owned: OwnedOrders,
}

/// The strategy's orders stop being "owned" when its task ends, however it ends.
impl Drop for Tracker {
    fn drop(&mut self) {
        let mut owned = self.owned.lock().unwrap_or_else(|e| e.into_inner());
        for id in self.u.entry_order_id.iter().chain(&self.u.exit_order_ids) {
            owned.remove(id);
        }
    }
}

impl Tracker {
    fn own(&self, order_id: i32) {
        self.owned.lock().unwrap_or_else(|e| e.into_inner()).insert(order_id);
    }

    fn emit(&mut self) {
        use StrategyState::*;
        self.u.requires_app = match self.u.state {
            Arming | Armed | WaitingDelayedData | Entering | Closing => true,
            Protected | Open | Unprotected => self.eod_by_app,
            Closed | Disarmed | Failed => false,
        };
        self.listener.on_update(self.u.clone());
    }

    fn set(&mut self, state: StrategyState, message: impl Into<String>) {
        self.u.state = state;
        self.u.message = message.into();
        self.emit();
    }
}

fn describe(e: impl std::fmt::Display) -> String {
    e.to_string()
}

async fn run(
    client: Arc<Client>,
    id: u64,
    spec: StrategySpec,
    listener: Arc<dyn StrategyListener>,
    mut cmds: mpsc::UnboundedReceiver<Cmd>,
    owned: OwnedOrders,
    risk: Arc<RiskGuard>,
) {
    let mut t = Tracker {
        u: StrategyUpdate {
            id,
            state: StrategyState::Arming,
            message: "Resolving contract…".into(),
            option_local_symbol: format!("{} {} {:?} {}", spec.option.symbol, spec.option.expiry, spec.option.right, spec.option.strike),
            contract_id: 0,
            underlying_last: None,
            underlying_delayed: false,
            entry_order_id: None,
            exit_order_ids: Vec::new(),
            filled_quantity: 0.0,
            average_fill: None,
            take_profit_price: None,
            stop_price: None,
            stop_limit_price: None,
            eod_close_at: None,
            exit_price: None,
            realized_pnl: None,
            can_close: false,
            requires_app: true,
        },
        listener,
        eod_by_app: false,
        owned,
    };
    t.emit();

    let now = Zoned::now().with_time_zone(eastern());
    let eod = match validate_spec(&spec, &now) {
        Ok(eod) => eod,
        Err(e) => return t.set(StrategyState::Failed, describe(e)),
    };
    t.u.eod_close_at = eod.as_ref().map(|e| e.condition.clone());
    let opt = match options::resolve_option(&client, &spec.option).await {
        Ok(o) => o,
        Err(e) => return t.set(StrategyState::Failed, describe(e)),
    };
    t.u.option_local_symbol = opt.local_symbol.clone();
    t.u.contract_id = opt.contract.contract_id;
    let zero_dte = spec.option.expiry == now.strftime("%Y%m%d").to_string();
    let exit_tif = if zero_dte { ibapi::orders::TimeInForce::Day } else { ibapi::orders::TimeInForce::GoodTillCanceled };

    if let Some(reason) = risk.halted() {
        return t.set(StrategyState::Failed, format!("Not armed: trading is halted for today ({reason})"));
    }
    let mut halt = risk.subscribe_halt();

    let mut ask = None;
    if let Some(trigger) = &spec.trigger {
        match wait_for_trigger(&client, trigger, &opt, spec.allow_delayed, &mut t, &mut cmds, &mut halt).await {
            Ok(TriggerEnd::Fired { ask: latest }) => ask = latest,
            Ok(TriggerEnd::Disarmed(why)) => return t.set(StrategyState::Disarmed, why),
            Err(e) => return t.set(StrategyState::Failed, e),
        }
    }

    // The last check before money moves: halt, daily loss, and the cost at the current ask.
    if ask.is_none() && risk.checks_cost() {
        ask = snapshot_ask(&client, &opt.contract).await;
    }
    if let Err(e) = risk.check_entry(ask.map(|a| a * spec.quantity * opt.multiplier)) {
        let state = if risk.halted().is_some() { StrategyState::Disarmed } else { StrategyState::Failed };
        return t.set(state, format!("Entry not sent: {e}"));
    }

    let (filled, fill) = match enter(&client, &opt, spec.quantity, &mut t, &mut cmds, &mut halt).await {
        Ok(v) => v,
        Err(EntryFailure::NotFilled(e)) => return t.set(StrategyState::Failed, e),
        Err(EntryFailure::Unknown { filled, message }) => {
            let id = t.u.entry_order_id.unwrap_or_default();
            return t.set(
                StrategyState::Unprotected,
                format!("Lost track of entry order #{id} ({message}) with {filled} filled. It may still fill and has no exits: check Orders and Positions."),
            );
        }
    };

    protect_and_monitor(&client, &opt, &spec, filled, fill, exit_tif, eod, &mut t, &mut cmds).await;
}

fn is_last(tick: &TickType) -> bool {
    matches!(tick, TickType::Last | TickType::DelayedLast)
}

enum TriggerEnd {
    /// With the option's latest ask, for the entry's cost check.
    Fired { ask: Option<f64> },
    Disarmed(String),
}

async fn wait_for_trigger(
    client: &Client,
    trigger: &Trigger,
    opt: &ResolvedContract,
    allow_delayed: bool,
    t: &mut Tracker,
    cmds: &mut mpsc::UnboundedReceiver<Cmd>,
    halt: &mut watch::Receiver<Option<String>>,
) -> Result<TriggerEnd, String> {
    if let Some(reason) = halt.borrow_and_update().clone() {
        return Ok(TriggerEnd::Disarmed(format!("Trading halted: {reason}")));
    }
    let symbol = trigger.underlying.trim().to_uppercase();
    let contract = ibapi::contracts::Contract::stock(symbol.clone()).build();
    let mut sub = client.market_data(&contract).subscribe().await.map_err(describe)?.filter_data();
    // The option's ask, kept current so the cost check at the trigger doesn't wait for a
    // quote. If this stream fails, the entry falls back to a snapshot.
    let mut asks = client.market_data(&opt.contract).subscribe().await.ok().map(|s| s.filter_data());
    let mut ask: Option<f64> = None;
    let mut halt_open = true;
    let watching = format!(
        "Watching {symbol} {} {}",
        if trigger.direction == TriggerDirection::RisesTo { "≥" } else { "≤" },
        trigger.price
    );
    t.set(StrategyState::Armed, watching.clone());

    let mut baseline_seen = false;
    loop {
        tokio::select! {
            cmd = cmds.recv() => match cmd {
                Some(Cmd::CloseNow) => continue,
                // Disarm, or the handle was dropped.
                Some(Cmd::Disarm) | None => return Ok(TriggerEnd::Disarmed("Disarmed before trigger".into())),
            },
            changed = halt.changed(), if halt_open => {
                if changed.is_err() {
                    halt_open = false;
                } else if let Some(reason) = halt.borrow_and_update().clone() {
                    return Ok(TriggerEnd::Disarmed(format!("Trading halted: {reason}")));
                }
            },
            tick = async { asks.as_mut()?.next().await }, if asks.is_some() => match tick {
                Some(Ok(tick)) => {
                    if let Some(a) = ask_of(&tick) {
                        ask = Some(a);
                    }
                }
                _ => asks = None,
            },
            item = sub.next() => {
                let tick = match item {
                    Some(Ok(tick)) => tick,
                    Some(Err(e)) => return Err(format!("{symbol} market data: {e}")),
                    None => return Err(format!("{symbol} market data ended")),
                };
                let last = match tick {
                    TickTypes::Price(p) if is_last(&p.tick_type) => p.price,
                    TickTypes::PriceSize(p) if is_last(&p.price_tick_type) => p.price,
                    TickTypes::MarketDataType(m) => {
                        t.u.underlying_delayed = matches!(m, MarketDataType::Delayed | MarketDataType::DelayedFrozen);
                        t.emit();
                        continue;
                    }
                    _ => continue,
                };
                if !(last.is_finite() && last > 0.0) {
                    continue;
                }
                t.u.underlying_last = Some(last);

                // The first last-trade tick is the price at arming time, not a new trade.
                if !baseline_seen {
                    baseline_seen = true;
                    if trigger_hit(trigger, last) {
                        return Err(format!(
                            "{symbol} is already at {last}, past the trigger {}; it must cross after arming",
                            trigger.price
                        ));
                    }
                    t.emit();
                    continue;
                }

                let gated = t.u.underlying_delayed && !allow_delayed;
                if gated {
                    t.set(StrategyState::WaitingDelayedData, format!("{symbol} data is delayed; trigger paused"));
                    continue;
                }
                if trigger_hit(trigger, last) {
                    t.u.message = format!("Triggered: {symbol} last {last}");
                    return Ok(TriggerEnd::Fired { ask });
                }
                if t.u.state != StrategyState::Armed {
                    t.set(StrategyState::Armed, watching.clone());
                } else {
                    t.emit();
                }
            }
        }
    }
}

enum EntryFailure {
    /// IB refused it or it ended unfilled: nothing was bought.
    NotFilled(String),
    /// Tracking was lost (e.g. the Gateway connection dropped): the order may still be
    /// working or filled, so this must never read as "nothing happened".
    Unknown { filled: f64, message: String },
}

/// Market buy; returns (filled qty, average fill).
async fn enter(
    client: &Client,
    opt: &ResolvedContract,
    quantity: f64,
    t: &mut Tracker,
    cmds: &mut mpsc::UnboundedReceiver<Cmd>,
    halt: &mut watch::Receiver<Option<String>>,
) -> Result<(f64, f64), EntryFailure> {
    let order_id = client.next_order_id();
    let mut order = order_builder::market_order(Action::Buy, quantity);
    order.tif = ibapi::orders::TimeInForce::Day;
    t.u.entry_order_id = Some(order_id);
    t.own(order_id);
    // Keep "Triggered: …" from the trigger step, if any.
    let prefix = if t.u.message.starts_with("Triggered") { format!("{}. ", t.u.message) } else { String::new() };
    t.set(StrategyState::Entering, format!("{prefix}Buying {quantity} at market (order #{order_id})"));

    let mut sub = track(client, order_id).await.map_err(|e| EntryFailure::NotFilled(format!("entry not sent: {e}")))?;
    // The tap does the tracking; dropping this subscription sends nothing to IB.
    let _ = client
        .place_order(order_id, &opt.contract, &order)
        .await
        .map_err(|e| EntryFailure::NotFilled(format!("entry rejected: {e}")))?;

    let mut filled = 0.0;
    let mut avg: Option<f64> = None;
    let mut cmds_open = true;
    let mut halt_open = true;
    loop {
        tokio::select! {
            // A halt cancels the entry like Disarm; any partial fill is still protected.
            changed = halt.changed(), if halt_open => {
                if changed.is_err() {
                    halt_open = false;
                } else if halt.borrow_and_update().is_some() {
                    halt_open = false;
                    let _ = client.cancel_order(order_id, "").await;
                    t.u.message = "Trading halted: cancelling entry…".into();
                    t.emit();
                }
            },
            cmd = cmds.recv(), if cmds_open => match cmd {
                Some(Cmd::Disarm) => {
                    // Cancel the working entry; any partial fill is protected below. The
                    // status tap keeps reporting after the cancel takes over the order id.
                    let _ = client.cancel_order(order_id, "").await;
                    t.u.message = "Cancelling entry…".into();
                    t.emit();
                }
                Some(Cmd::CloseNow) => {}
                None => cmds_open = false,
            },
            item = sub.next() => match item {
                Some(Ok(s)) => {
                    filled = s.filled;
                    if let Some(p) = s.average_fill_price.filter(|p| *p > 0.0) {
                        avg = Some(p);
                    }
                    t.u.filled_quantity = filled;
                    t.u.average_fill = avg;
                    match s.status {
                        OrderStatusKind::Filled => {
                            return avg.map(|a| (filled, a)).ok_or(EntryFailure::Unknown { filled, message: "filled without a price".into() });
                        }
                        OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled | OrderStatusKind::Inactive => {
                            if filled > 0.0 && let Some(a) = avg {
                                return Ok((filled, a)); // partial fill: protect what we have
                            }
                            let why = if s.why_held.is_empty() { String::new() } else { format!(": {}", s.why_held) };
                            return Err(EntryFailure::NotFilled(format!("entry {:?}{why}", s.status)));
                        }
                        _ => t.emit(),
                    }
                }
                // The tap reports an IB error only before any status: a rejection. Anything
                // else leaves the order's fate unknown.
                Some(Err(ibapi::Error::Notice(n))) if filled == 0.0 => {
                    return Err(EntryFailure::NotFilled(format!("entry rejected: {}", n.message)));
                }
                Some(Err(e)) => return Err(EntryFailure::Unknown { filled, message: e.to_string() }),
                None => return Err(EntryFailure::Unknown { filled, message: "order stream ended".into() }),
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Exit {
    TakeProfit,
    Stop,
    EodClose,
    CloseNow,
}

impl std::fmt::Display for Exit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Exit::TakeProfit => "take-profit",
            Exit::Stop => "stop-loss",
            Exit::EodClose => "end-of-day close",
            Exit::CloseNow => "close-now",
        })
    }
}

type StatusStream = Pin<Box<dyn Stream<Item = Result<OrderStatus, ibapi::Error>> + Send>>;
type ExitStream = Pin<Box<dyn Stream<Item = (Exit, i32, Result<OrderStatus, ibapi::Error>)> + Send>>;

/// One order's statuses from ibapi's tap (starting with the latest one seen), which a
/// cancel or modify re-registering the order id doesn't displace. Open it before placing.
async fn track(client: &Client, order_id: i32) -> Result<StatusStream, ibapi::Error> {
    Ok(Box::pin(client.order_status_stream(order_id).await?.filter_data()))
}

/// Places one sell-to-close in the OCA group and waits briefly for IB to accept it.
async fn place_exit(
    client: &Client,
    opt: &ResolvedContract,
    kind: Exit,
    mut order: Order,
    oca: &str,
    tif: ibapi::orders::TimeInForce,
    t: &mut Tracker,
) -> Result<(i32, ExitStream), String> {
    order.oca_group = oca.to_string();
    order.oca_type = OcaType::ReduceWithBlock;
    order.tif = tif;
    order.transmit = true;
    let order_id = client.next_order_id();
    t.own(order_id);
    t.u.exit_order_ids.push(order_id);
    let mut sub = track(client, order_id).await.map_err(|e| format!("{kind} not sent: {e}"))?;
    // The tap does the tracking; dropping this subscription sends nothing to IB.
    let _ = client
        .place_order(order_id, &opt.contract, &order)
        .await
        .map_err(|e| format!("{kind} rejected: {e}"))?;

    // Accepted once IB reports a working status; rejections come back as an error or Inactive.
    // Everything read here is replayed to the monitor: a market close can report Filled
    // as its very first status.
    let mut seen: Vec<OrderStatus> = Vec::new();
    match tokio::time::timeout(Duration::from_secs(5), sub.next()).await {
        Ok(Some(Ok(s))) => match s.status {
            OrderStatusKind::Inactive | OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled => {
                return Err(format!("{kind} {:?} {}", s.status, s.why_held));
            }
            _ => seen.push(s),
        },
        Ok(Some(Err(e))) => return Err(format!("{kind} rejected: {e}")),
        Ok(None) => return Err(format!("{kind}: order stream ended")),
        Err(_) => {} // timeout: no status yet, keep tracking
    }
    let replay = futures::stream::iter(seen.into_iter().map(Ok));
    Ok((order_id, Box::pin(replay.chain(sub).map(move |r| (kind, order_id, r)))))
}

/// Fills across the exit orders. Under ReduceWithBlock a partial fill on one exit shrinks
/// the others, so several exits can each sell part of the position.
#[derive(Debug, Default)]
pub(crate) struct ExitFills {
    /// (order id, filled, average price)
    by_order: Vec<(i32, f64, Option<f64>)>,
}

impl ExitFills {
    /// `filled` is the order's cumulative fill, as IB reports it.
    pub(crate) fn update(&mut self, order_id: i32, filled: f64, avg: Option<f64>) {
        let avg = avg.filter(|p| positive(*p));
        match self.by_order.iter_mut().find(|e| e.0 == order_id) {
            Some(e) => {
                e.1 = e.1.max(filled);
                e.2 = avg.or(e.2);
            }
            None => self.by_order.push((order_id, filled, avg)),
        }
    }

    pub(crate) fn filled(&self) -> f64 {
        self.by_order.iter().map(|e| e.1).sum()
    }

    /// Volume-weighted across exits; None if any fill has no price yet.
    pub(crate) fn average(&self) -> Option<f64> {
        let filled = self.filled();
        if filled <= 0.0 {
            return None;
        }
        let mut notional = 0.0;
        for (_, qty, avg) in self.by_order.iter().filter(|e| e.1 > 0.0) {
            notional += qty * (*avg)?;
        }
        Some(notional / filled)
    }
}

#[allow(clippy::too_many_arguments)]
async fn protect_and_monitor(
    client: &Client,
    opt: &ResolvedContract,
    spec: &StrategySpec,
    quantity: f64,
    fill: f64,
    tif: ibapi::orders::TimeInForce,
    eod: Option<EodClose>,
    t: &mut Tracker,
    cmds: &mut mpsc::UnboundedReceiver<Cmd>,
) {
    t.u.filled_quantity = quantity;
    t.u.average_fill = Some(fill);
    let oca = oca_group_name(t.u.entry_order_id.unwrap_or_default());
    let mut exits: SelectAll<ExitStream> = SelectAll::new();
    let mut problems: Vec<String> = Vec::new();

    // A pricing failure still falls through to the monitor loop, so close-now works.
    let plan = plan_exits(fill, quantity, opt.multiplier, spec.take_profit, spec.stop_loss, &opt.increments).unwrap_or_else(|e| {
        problems.push(format!("exits not placed: {e}"));
        ExitPlan::default()
    });
    t.u.take_profit_price = plan.take_profit;
    t.u.stop_price = plan.stop;
    t.u.stop_limit_price = plan.stop_limit;

    let mut orders: Vec<(Exit, Order)> = Vec::new();
    if let Some(tp) = plan.take_profit {
        orders.push((Exit::TakeProfit, order_builder::limit_order(Action::Sell, quantity, tp)));
    }
    if let Some(stop) = plan.stop {
        let mut o = order_builder::stop(Action::Sell, quantity, stop);
        if let Some(limit) = plan.stop_limit {
            o.order_type = "STP LMT".into();
            o.limit_price = Some(limit);
        }
        orders.push((Exit::Stop, o));
    }
    if let Some(eod) = &eod {
        let mut o = order_builder::market_order(Action::Sell, quantity);
        o.conditions = vec![OrderCondition::Time(TimeCondition::builder().greater_than(eod.condition.clone()).build())];
        orders.push((Exit::EodClose, o));
    }

    let mut eod_fallback: Option<jiff::Timestamp> = None;
    let mut placed = 0;
    for (kind, order) in orders {
        match place_exit(client, opt, kind, order, &oca, tif.clone(), t).await {
            Ok((_, stream)) => {
                exits.push(stream);
                placed += 1;
            }
            Err(e) if kind == Exit::EodClose => {
                // IB refused the time-conditioned OCA member: close from the app instead.
                eod_fallback = eod.as_ref().map(|e| e.deadline);
                t.eod_by_app = true;
                problems.push(format!("{e}; the app will close at the EOD time (keep it open)"));
            }
            Err(e) => problems.push(e),
        }
    }

    let protective_failed = problems.iter().any(|p| !p.contains("keep it open"));
    let summary = format!("Filled {quantity} @ {fill}");
    t.u.can_close = true;
    if protective_failed {
        t.set(StrategyState::Unprotected, format!("{summary}. {}", problems.join("; ")));
    } else if exits.is_empty() && eod_fallback.is_none() {
        t.set(StrategyState::Open, format!("{summary}. No exits set."));
    } else {
        let note = if problems.is_empty() { String::new() } else { format!(" {}", problems.join("; ")) };
        t.set(StrategyState::Protected, format!("{summary}. Exits working.{note}"));
    }

    let has_eod_fallback = eod_fallback.is_some();
    let eod_sleep = async move {
        match eod_fallback {
            Some(deadline) => {
                let wait = deadline.duration_since(jiff::Timestamp::now()).unsigned_abs();
                tokio::time::sleep(wait).await;
            }
            None => std::future::pending::<()>().await,
        }
    };
    tokio::pin!(eod_sleep);

    let mut cmds_open = true;
    let mut closing = false;
    let mut cancelled: Vec<i32> = Vec::new();
    let mut fills = ExitFills::default();
    loop {
        tokio::select! {
            cmd = cmds.recv(), if cmds_open => match cmd {
                Some(Cmd::CloseNow) if !closing => {
                    closing = true;
                    placed += 1;
                    close_now(client, opt, quantity - fills.filled(), &oca, tif.clone(), Exit::CloseNow, &mut exits, t).await;
                }
                Some(_) => {}
                None => cmds_open = false,
            },
            _ = &mut eod_sleep, if has_eod_fallback && !closing => {
                closing = true;
                placed += 1;
                close_now(client, opt, quantity - fills.filled(), &oca, tif.clone(), Exit::EodClose, &mut exits, t).await;
            }
            item = exits.next(), if !exits.is_empty() => {
                let Some((kind, order_id, item)) = item else { continue };
                match item {
                    Ok(s) => {
                        let sold_before = fills.filled();
                        if s.filled > 0.0 {
                            fills.update(order_id, s.filled, s.average_fill_price);
                        }
                        let sold = fills.filled();
                        if sold >= quantity - 1e-9 {
                            t.u.exit_price = fills.average();
                            t.u.realized_pnl = t.u.exit_price.map(|exit| ((exit - fill) * quantity * opt.multiplier * 100.0).round() / 100.0);
                            t.u.can_close = false;
                            let at = t.u.exit_price.map_or("unknown price".into(), |p| p.to_string());
                            return t.set(StrategyState::Closed, format!("Closed by {kind} @ {at}"));
                        }
                        if sold > sold_before {
                            t.set(t.u.state, format!("{kind} sold {sold} of {quantity}; the other exits were reduced to the remaining {}", quantity - sold));
                        }
                        // OCA siblings are cancelled when the position is sold, and those
                        // cancels can arrive before the fill. Only alarm once every exit
                        // is gone without the whole position sold.
                        if matches!(s.status, OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled | OrderStatusKind::Inactive)
                            && !cancelled.contains(&order_id)
                        {
                            cancelled.push(order_id);
                            if cancelled.len() == placed && !closing {
                                t.set(StrategyState::Unprotected, format!("All exit orders were cancelled; {} still open", quantity - sold));
                            }
                        }
                    }
                    Err(e) => t.set(t.u.state, format!("Lost tracking of the {kind} order (it stays at IB): {e}")),
                }
            }
            else => {
                // No exits left to watch and no commands possible.
                return;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn close_now(
    client: &Client,
    opt: &ResolvedContract,
    quantity: f64,
    oca: &str,
    tif: ibapi::orders::TimeInForce,
    kind: Exit,
    exits: &mut SelectAll<ExitStream>,
    t: &mut Tracker,
) {
    let order = order_builder::market_order(Action::Sell, quantity);
    match place_exit(client, opt, kind, order, oca, tif, t).await {
        Ok((order_id, stream)) => {
            exits.push(stream);
            t.u.can_close = false;
            t.set(StrategyState::Closing, format!("{kind}: selling {quantity} at market (order #{order_id})"));
        }
        Err(e) => t.set(StrategyState::Unprotected, format!("{kind} failed: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PENNY: &[(f64, f64)] = &[(0.0, 0.01)];
    const NICKEL: &[(f64, f64)] = &[(0.0, 0.01), (3.0, 0.05)];

    fn trig(direction: TriggerDirection, price: f64) -> Trigger {
        Trigger { underlying: "SPY".into(), direction, price }
    }

    fn spec() -> StrategySpec {
        StrategySpec {
            option: OptionSpec { symbol: "SPY".into(), expiry: "20261022".into(), right: OptionRight::Call, strike: 670.0 },
            quantity: 2.0,
            trigger: Some(trig(TriggerDirection::RisesTo, 670.0)),
            take_profit: Some(Target::Percent { value: 50.0 }),
            stop_loss: Some(StopSpec { target: Target::Percent { value: 30.0 }, kind: StopKind::StopMarket }),
            eod_close: Some("15:50".into()),
            allow_delayed: false,
        }
    }

    fn at(hh: i8, mm: i8) -> Zoned {
        jiff::civil::date(2026, 10, 22).at(hh, mm, 0, 0).to_zoned(eastern()).unwrap()
    }

    #[test]
    fn oca_names_never_repeat() {
        // Same entry id, as happens across connections.
        let a = oca_group_name(1);
        let b = oca_group_name(1);
        assert_ne!(a, b);
        assert!(a.starts_with("ibkr-swift-") && a.ends_with("-1"));
    }

    #[test]
    fn trigger_directions() {
        assert!(trigger_hit(&trig(TriggerDirection::RisesTo, 670.0), 670.0));
        assert!(trigger_hit(&trig(TriggerDirection::RisesTo, 670.0), 670.5));
        assert!(!trigger_hit(&trig(TriggerDirection::RisesTo, 670.0), 669.99));
        assert!(trigger_hit(&trig(TriggerDirection::FallsTo, 660.0), 659.0));
        assert!(!trigger_hit(&trig(TriggerDirection::FallsTo, 660.0), 660.01));
    }

    #[test]
    fn percent_exits() {
        let p = plan_exits(1.00, 2.0, 100.0, Some(Target::Percent { value: 50.0 }), spec().stop_loss, PENNY).unwrap();
        assert_eq!(p, ExitPlan { take_profit: Some(1.5), stop: Some(0.7), stop_limit: None });
    }

    #[test]
    fn dollar_exits_use_quantity_and_multiplier() {
        // $100 on 2 contracts × 100 = $0.50 per contract.
        let p = plan_exits(
            2.00,
            2.0,
            100.0,
            Some(Target::Dollars { value: 100.0 }),
            Some(StopSpec { target: Target::Dollars { value: 60.0 }, kind: StopKind::StopLimit { limit_offset: 0.10 } }),
            PENNY,
        )
        .unwrap();
        assert_eq!(p, ExitPlan { take_profit: Some(2.5), stop: Some(1.7), stop_limit: Some(1.6) });
    }

    #[test]
    fn exits_round_away_from_fill_in_bands() {
        // TP rounds up into the nickel band, stop rounds down.
        let p = plan_exits(2.43, 1.0, 100.0, Some(Target::Percent { value: 25.0 }), spec().stop_loss, NICKEL).unwrap();
        assert_eq!(p.take_profit, Some(3.05)); // 3.0375 → 3.05
        assert_eq!(p.stop, Some(1.70)); // 1.701 → 1.70
    }

    #[test]
    fn stop_floors_at_one_tick() {
        let sl = StopSpec { target: Target::Dollars { value: 1000.0 }, kind: StopKind::StopMarket };
        let p = plan_exits(0.50, 1.0, 100.0, None, Some(sl), PENNY).unwrap();
        assert_eq!(p.stop, Some(0.01));
    }

    #[test]
    fn exit_fills_add_up_across_exits() {
        let mut f = ExitFills::default();
        f.update(10, 1.0, Some(1.50)); // take-profit sells 1 of 2
        f.update(10, 1.0, None); // repeated status without a price keeps the price
        f.update(11, 1.0, Some(0.70)); // reduced stop sells the other
        assert_eq!(f.filled(), 2.0);
        assert!((f.average().unwrap() - 1.10).abs() < 1e-9);

        let mut g = ExitFills::default();
        g.update(12, 1.0, None);
        assert_eq!(g.average(), None, "never report a made-up exit price");
    }

    #[test]
    fn validates_specs() {
        assert!(validate_spec(&spec(), &at(10, 0)).unwrap().is_some());
        assert_eq!(validate_spec(&spec(), &at(10, 0)).unwrap().unwrap().condition, "20261022 15:50:00 US/Eastern");

        let bad = |f: fn(&mut StrategySpec)| {
            let mut s = spec();
            f(&mut s);
            validate_spec(&s, &at(10, 0)).is_err()
        };
        assert!(bad(|s| s.quantity = 0.0));
        assert!(bad(|s| s.quantity = 1.5));
        assert!(bad(|s| s.option.expiry = "20261021".into()));
        assert!(bad(|s| s.take_profit = Some(Target::Percent { value: 0.0 })));
        assert!(bad(|s| s.stop_loss = Some(StopSpec { target: Target::Percent { value: 100.0 }, kind: StopKind::StopMarket })));
        assert!(bad(|s| s.eod_close = Some("16:00".into())));
        assert!(bad(|s| s.eod_close = Some("3:50pm".into())));
        // Close time already passed.
        assert!(validate_spec(&spec(), &at(15, 55)).is_err());
        // Later expiry is fine; no EOD is fine.
        let mut s = spec();
        s.option.expiry = "20261120".into();
        s.eod_close = None;
        assert!(validate_spec(&s, &at(15, 55)).unwrap().is_none());
    }
}
