//! Trigger → market entry → OCA-protected exits, one Tokio task per strategy.
//!
//! Safety invariants (see CLAUDE.md):
//! - The trigger never fires on delayed data unless `allow_delayed` (forced off on live).
//! - The trigger must be *crossed* after arming: the first last-trade tick is a baseline,
//!   and arming fails if the baseline is already through the trigger.
//! - The entry is sent at most once (the task only moves forward).
//! - Every sell-to-close (take-profit, stop, EOD close, close-now) shares one OCA group with
//!   CancelWithBlock, so at most one can fill and none can open a short.

use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures::stream::{SelectAll, Stream, StreamExt};
use ibapi::Client;
use ibapi::contracts::tick_types::TickType;
use ibapi::market_data::MarketDataType;
use ibapi::market_data::realtime::TickTypes;
use ibapi::orders::conditions::TimeCondition;
use ibapi::orders::{Action, OcaType, Order, OrderCondition, OrderStatusKind, PlaceOrder, order_builder};
use ibapi::subscriptions::SubscriptionItemStreamExt;
use jiff::Zoned;
use jiff::civil::Time;
use jiff::tz::TimeZone;
use tokio::sync::mpsc;

use crate::options::{self, ResolvedOption, Round};
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

pub(crate) fn spawn(
    runtime: &tokio::runtime::Runtime,
    client: Arc<Client>,
    spec: StrategySpec,
    listener: Arc<dyn StrategyListener>,
) -> Arc<StrategyHandle> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::unbounded_channel();
    runtime.spawn(run(client, id, spec, listener, rx));
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
}

impl Tracker {
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
) {
    let mut t = Tracker {
        u: StrategyUpdate {
            id,
            state: StrategyState::Arming,
            message: "Resolving contract…".into(),
            option_local_symbol: format!("{} {} {:?} {}", spec.option.symbol, spec.option.expiry, spec.option.right, spec.option.strike),
            underlying_last: None,
            underlying_delayed: false,
            entry_order_id: None,
            filled_quantity: 0.0,
            average_fill: None,
            take_profit_price: None,
            stop_price: None,
            stop_limit_price: None,
            eod_close_at: None,
            exit_price: None,
            realized_pnl: None,
            requires_app: true,
        },
        listener,
        eod_by_app: false,
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
    let zero_dte = spec.option.expiry == now.strftime("%Y%m%d").to_string();
    let exit_tif = if zero_dte { ibapi::orders::TimeInForce::Day } else { ibapi::orders::TimeInForce::GoodTillCanceled };

    if let Some(trigger) = &spec.trigger {
        match wait_for_trigger(&client, trigger, spec.allow_delayed, &mut t, &mut cmds).await {
            Ok(true) => {}
            Ok(false) => return t.set(StrategyState::Disarmed, "Disarmed before trigger"),
            Err(e) => return t.set(StrategyState::Failed, e),
        }
    }

    let (filled, fill) = match enter(&client, &opt, spec.quantity, &mut t, &mut cmds).await {
        Ok(v) => v,
        Err((0.0, e)) => return t.set(StrategyState::Failed, e),
        Err((filled, e)) => return t.set(StrategyState::Unprotected, format!("{filled} filled but entry tracking failed: {e}")),
    };

    protect_and_monitor(&client, &opt, &spec, filled, fill, exit_tif, eod, &mut t, &mut cmds).await;
}

fn is_last(tick: &TickType) -> bool {
    matches!(tick, TickType::Last | TickType::DelayedLast)
}

/// Ok(true) = fired, Ok(false) = disarmed.
async fn wait_for_trigger(
    client: &Client,
    trigger: &Trigger,
    allow_delayed: bool,
    t: &mut Tracker,
    cmds: &mut mpsc::UnboundedReceiver<Cmd>,
) -> Result<bool, String> {
    let symbol = trigger.underlying.trim().to_uppercase();
    let contract = ibapi::contracts::Contract::stock(symbol.clone()).build();
    let mut sub = client.market_data(&contract).subscribe().await.map_err(describe)?.filter_data();
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
                Some(Cmd::Disarm) | None => return Ok(false),
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
                    return Ok(true);
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

/// Market buy; returns (filled qty, average fill). Err carries any partial fill.
async fn enter(
    client: &Client,
    opt: &ResolvedOption,
    quantity: f64,
    t: &mut Tracker,
    cmds: &mut mpsc::UnboundedReceiver<Cmd>,
) -> Result<(f64, f64), (f64, String)> {
    let order_id = client.next_order_id();
    let mut order = order_builder::market_order(Action::Buy, quantity);
    order.tif = ibapi::orders::TimeInForce::Day;
    t.u.entry_order_id = Some(order_id);
    // Keep "Triggered: …" from the trigger step, if any.
    let prefix = if t.u.message.starts_with("Triggered") { format!("{}. ", t.u.message) } else { String::new() };
    t.set(StrategyState::Entering, format!("{prefix}Buying {quantity} at market (order #{order_id})"));

    let mut sub = client
        .place_order(order_id, &opt.contract, &order)
        .await
        .map_err(|e| (0.0, format!("entry rejected: {e}")))?
        .filter_data();

    let mut filled = 0.0;
    let mut avg: Option<f64> = None;
    let mut cmds_open = true;
    loop {
        tokio::select! {
            cmd = cmds.recv(), if cmds_open => match cmd {
                Some(Cmd::Disarm) => {
                    // Cancel the working entry; any partial fill is protected below.
                    let _ = client.cancel_order(order_id, "").await;
                    t.u.message = "Cancelling entry…".into();
                    t.emit();
                }
                Some(Cmd::CloseNow) => {}
                None => cmds_open = false,
            },
            item = sub.next() => match item {
                Some(Ok(PlaceOrder::OrderStatus(s))) => {
                    filled = s.filled;
                    if let Some(p) = s.average_fill_price.filter(|p| *p > 0.0) {
                        avg = Some(p);
                    }
                    t.u.filled_quantity = filled;
                    t.u.average_fill = avg;
                    match s.status {
                        OrderStatusKind::Filled => {
                            return avg.map(|a| (filled, a)).ok_or((filled, "filled without a price".into()));
                        }
                        OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled | OrderStatusKind::Inactive => {
                            if filled > 0.0 && let Some(a) = avg {
                                return Ok((filled, a)); // partial fill: protect what we have
                            }
                            let why = if s.why_held.is_empty() { String::new() } else { format!(": {}", s.why_held) };
                            return Err((0.0, format!("entry {:?}{why}", s.status)));
                        }
                        _ => t.emit(),
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(e)) => return Err((filled, format!("entry: {e}"))),
                None => return Err((filled, "entry order stream ended before fill".into())),
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

type ExitStream = Pin<Box<dyn Stream<Item = (Exit, i32, Result<PlaceOrder, ibapi::Error>)> + Send>>;

/// Places one sell-to-close in the OCA group and waits briefly for IB to accept it.
async fn place_exit(
    client: &Client,
    opt: &ResolvedOption,
    kind: Exit,
    mut order: Order,
    oca: &str,
    tif: ibapi::orders::TimeInForce,
) -> Result<(i32, ExitStream), String> {
    order.oca_group = oca.to_string();
    order.oca_type = OcaType::CancelWithBlock;
    order.tif = tif;
    order.transmit = true;
    let order_id = client.next_order_id();
    let mut sub = client
        .place_order(order_id, &opt.contract, &order)
        .await
        .map_err(|e| format!("{kind} rejected: {e}"))?
        .filter_data();

    // Accepted once IB reports a working status; rejections come back as an error or Inactive.
    let accepted = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(item) = sub.next().await {
            match item {
                Ok(PlaceOrder::OrderStatus(s)) => match s.status {
                    OrderStatusKind::Inactive | OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled => {
                        return Err(format!("{kind} {:?} {}", s.status, s.why_held));
                    }
                    _ => return Ok(()),
                },
                Ok(_) => {}
                Err(e) => return Err(format!("{kind} rejected: {e}")),
            }
        }
        Err(format!("{kind}: order stream ended"))
    })
    .await;
    match accepted {
        Ok(Ok(())) | Err(_) => {} // timeout: no status yet, keep tracking
        Ok(Err(e)) => return Err(e),
    }
    Ok((order_id, Box::pin(sub.map(move |r| (kind, order_id, r)))))
}

#[allow(clippy::too_many_arguments)]
async fn protect_and_monitor(
    client: &Client,
    opt: &ResolvedOption,
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
    let plan = match plan_exits(fill, quantity, opt.multiplier, spec.take_profit, spec.stop_loss, &opt.increments) {
        Ok(p) => p,
        Err(e) => return t.set(StrategyState::Unprotected, format!("Filled {quantity} @ {fill}, but exits not placed: {e}")),
    };
    t.u.take_profit_price = plan.take_profit;
    t.u.stop_price = plan.stop;
    t.u.stop_limit_price = plan.stop_limit;

    let oca = format!("ibkr-swift-{}-{}", t.u.entry_order_id.unwrap_or_default(), t.u.id);
    let mut exits: SelectAll<ExitStream> = SelectAll::new();
    let mut problems: Vec<String> = Vec::new();

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
        match place_exit(client, opt, kind, order, &oca, tif.clone()).await {
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
    loop {
        tokio::select! {
            cmd = cmds.recv(), if cmds_open => match cmd {
                Some(Cmd::CloseNow) if !closing => {
                    closing = true;
                    placed += 1;
                    close_now(client, opt, quantity, &oca, tif.clone(), Exit::CloseNow, &mut exits, t).await;
                }
                Some(_) => {}
                None => cmds_open = false,
            },
            _ = &mut eod_sleep, if has_eod_fallback && !closing => {
                closing = true;
                placed += 1;
                close_now(client, opt, quantity, &oca, tif.clone(), Exit::EodClose, &mut exits, t).await;
            }
            item = exits.next(), if !exits.is_empty() => {
                let Some((kind, order_id, item)) = item else { continue };
                match item {
                    Ok(PlaceOrder::OrderStatus(s)) => match s.status {
                        OrderStatusKind::Filled => {
                            let exit = s.average_fill_price.unwrap_or(0.0);
                            t.u.exit_price = Some(exit);
                            t.u.realized_pnl = Some((exit - fill) * quantity * opt.multiplier);
                            return t.set(StrategyState::Closed, format!("Closed by {kind} @ {exit}"));
                        }
                        // OCA siblings are cancelled when one exit fills, and those
                        // cancels can arrive before the fill. Only alarm once every exit
                        // is gone without a fill.
                        OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled | OrderStatusKind::Inactive
                            if !cancelled.contains(&order_id) =>
                        {
                            cancelled.push(order_id);
                            if cancelled.len() == placed && !closing {
                                t.set(StrategyState::Unprotected, "All exit orders were cancelled; the position is open");
                            }
                        }
                        _ => {}
                    },
                    Ok(_) => {}
                    Err(e) => t.set(t.u.state, format!("{kind}: {e}")),
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
    opt: &ResolvedOption,
    quantity: f64,
    oca: &str,
    tif: ibapi::orders::TimeInForce,
    kind: Exit,
    exits: &mut SelectAll<ExitStream>,
    t: &mut Tracker,
) {
    let order = order_builder::market_order(Action::Sell, quantity);
    match place_exit(client, opt, kind, order, oca, tif).await {
        Ok((order_id, stream)) => {
            exits.push(stream);
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
