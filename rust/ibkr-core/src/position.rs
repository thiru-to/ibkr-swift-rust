//! Acting on an existing position: close it with a capped limit, attach a stop and/or
//! take-profit, or change the price of a working order.
//!
//! Safety rules (see CLAUDE.md):
//! - Positions a running strategy manages are refused; close those with the strategy's
//!   Close Now so every exit stays in its OCA group.
//! - Close cancels this client's working orders on the contract and waits for IB to
//!   confirm each one *before* sending the close, so an exit can't fill alongside it.
//! - The quantity always comes from IB after those cancels, and must match what the user
//!   reviewed; anything unexpected aborts before an order is sent.

use std::collections::HashMap;
use std::time::Duration;

use futures::StreamExt;
use ibapi::Client;
use ibapi::accounts::PositionUpdate;
use ibapi::contracts::Contract;
use ibapi::orders::{Action, CancelOrder, OcaType, Order, OrderData, Orders, order_builder};
use ibapi::subscriptions::{SubscriptionItem, SubscriptionItemStreamExt};

use crate::options::{self, ResolvedContract, Round};
use crate::orders;
use crate::session::await_ack;
use crate::strategy::{self, OwnedOrders};
use crate::types::*;

/// How long to wait for IB to list orders or positions, or to confirm a cancel.
const WAIT: Duration = Duration::from_secs(5);

fn invalid(message: impl Into<String>) -> IbkrError {
    IbkrError::Invalid { message: message.into() }
}

fn api(message: impl Into<String>) -> IbkrError {
    IbkrError::Api { message: message.into() }
}

/// What position actions need from the session.
pub(crate) struct Ctx<'a> {
    pub client: &'a Client,
    pub account: &'a str,
    pub client_id: i32,
    pub owned: &'a OwnedOrders,
}

impl Ctx<'_> {
    fn strategy_owns(&self, order_id: i32) -> bool {
        self.owned.lock().unwrap_or_else(|e| e.into_inner()).contains(&order_id)
    }
}

/// Every working order IB reports (all clients), optionally for one contract.
pub(crate) async fn working_orders(client: &Client, contract_id: Option<i32>) -> Result<Vec<OrderData>, IbkrError> {
    let mut sub = client.all_open_orders().await?.filter_data();
    // The same order can be reported more than once; keep the latest.
    let mut found: HashMap<(i32, i32, i64), OrderData> = HashMap::new();
    let read = async {
        while let Some(item) = sub.next().await {
            if let Orders::OrderData(d) = item? {
                found.insert((d.order.client_id, d.order_id, d.order.perm_id), d);
            }
        }
        Ok::<_, IbkrError>(())
    };
    tokio::time::timeout(WAIT, read)
        .await
        .map_err(|_| api("IB didn't list open orders in time. Nothing was sent."))??;
    Ok(found
        .into_values()
        .filter(|d| orders::group(&d.order_state.status) == OrderStatusGroup::Open)
        .filter(|d| contract_id.is_none_or(|id| d.contract.contract_id == id))
        .collect())
}

/// The account's current position in the contract, straight from IB (0 if flat).
pub(crate) async fn current_position(client: &Client, account: &str, contract_id: i32) -> Result<f64, IbkrError> {
    position_where(client, account, |c| c.contract_id == contract_id).await
}

/// Every position the account holds, by contract id, straight from IB.
pub(crate) async fn all_positions(client: &Client, account: &str) -> Result<HashMap<i32, f64>, IbkrError> {
    let mut sub = client.positions().await?.filter_data();
    let mut held = HashMap::new();
    let read = async {
        while let Some(item) = sub.next().await {
            match item? {
                PositionUpdate::Position(p) if p.account == account => {
                    held.insert(p.contract.contract_id, p.position);
                }
                PositionUpdate::Position(_) => {}
                PositionUpdate::PositionEnd => return Ok(()),
            }
        }
        Err(api("the positions stream ended"))
    };
    tokio::time::timeout(WAIT, read).await.map_err(|_| api("IB didn't report positions in time"))??;
    Ok(held)
}

async fn position_where(client: &Client, account: &str, matches: impl Fn(&Contract) -> bool) -> Result<f64, IbkrError> {
    let mut sub = client.positions().await?.filter_data();
    let mut quantity = 0.0;
    let read = async {
        while let Some(item) = sub.next().await {
            match item? {
                PositionUpdate::Position(p) if p.account == account && matches(&p.contract) => quantity = p.position,
                PositionUpdate::Position(_) => {}
                PositionUpdate::PositionEnd => return Ok(()),
            }
        }
        Err(api("the positions stream ended"))
    };
    tokio::time::timeout(WAIT, read)
        .await
        .map_err(|_| api("IB didn't report positions in time. Nothing was sent."))??;
    Ok(quantity)
}

/// The quantity must still be what the user reviewed, or the order would be wrong.
fn check_quantity(actual: f64, expected: f64) -> Result<(), IbkrError> {
    if !actual.is_finite() || !expected.is_finite() || expected == 0.0 { return Err(invalid("Position quantities must be finite and the reviewed quantity nonzero.")); }
    if actual == 0.0 {
        return Err(invalid("The position is already flat. Nothing was sent."));
    }
    if (actual - expected).abs() > 1e-9 {
        return Err(invalid(format!("The position changed to {actual} (you reviewed {expected}). Nothing was sent; review it again.")));
    }
    Ok(())
}

/// Cancels one order and waits for IB to confirm. Fails if it filled any further
/// meanwhile: IB's position report can lag a fill, so the close quantity can't be trusted.
async fn cancel_confirmed(client: &Client, d: &OrderData) -> Result<(), String> {
    let id = d.order_id;
    let mut sub = client.cancel_order(id, "").await.map_err(|e| format!("order #{id} couldn't be cancelled: {e}"))?;
    let known_fill = d.order.filled_quantity;
    let confirm = async {
        while let Some(item) = sub.next().await {
            match item {
                Ok(SubscriptionItem::Data(CancelOrder::OrderStatus(s))) => {
                    if s.filled > known_fill + 1e-9 {
                        return Err(format!("order #{id} filled {} while it was being cancelled", s.filled - known_fill));
                    }
                    match orders::group(&s.status) {
                        OrderStatusGroup::Cancelled | OrderStatusGroup::Inactive => return Ok(()),
                        OrderStatusGroup::Filled => return Err(format!("order #{id} filled while it was being cancelled")),
                        _ => {}
                    }
                }
                Ok(SubscriptionItem::Notice(_)) => {}
                Err(e) => return Err(format!("order #{id} couldn't be cancelled: {e}")),
            }
        }
        Err(format!("lost contact with IB while cancelling order #{id}"))
    };
    tokio::time::timeout(WAIT, confirm)
        .await
        .unwrap_or_else(|_| Err(format!("IB didn't confirm order #{id} was cancelled")))
}

/// Closes the whole position with a limit order. `limit_price` is the capped price the
/// user reviewed (bid − cap to sell, ask + cap to buy); it's rounded to a valid tick,
/// toward filling.
pub(crate) async fn close(ctx: Ctx<'_>, contract_id: i32, expected_quantity: f64, limit_price: f64) -> Result<PlacedOrder, IbkrError> {
    close_order(ctx, contract_id, Some(expected_quantity), Some(limit_price)).await
}

pub(crate) async fn close_order(ctx: Ctx<'_>, contract_id: i32, expected_quantity: Option<f64>, limit_price: Option<f64>) -> Result<PlacedOrder, IbkrError> {
    if limit_price.is_some_and(|p| !(p.is_finite() && p > 0.0)) {
        return Err(invalid("limit price must be greater than 0"));
    }
    if expected_quantity.is_some_and(|q| !q.is_finite() || q == 0.0) { return Err(invalid("Review a nonzero finite position quantity.")); }
    let resolved = options::resolve_contract_id(ctx.client, contract_id).await?;
    let working: Vec<_> = working_orders(ctx.client, Some(contract_id)).await?.into_iter().filter(|d| d.order.account == ctx.account || d.order.account.is_empty()).collect();
    if working.iter().any(|d| ctx.strategy_owns(d.order_id) && d.order.client_id == ctx.client_id) {
        return Err(invalid("A running strategy manages this position. Close it with the strategy's Close Now so its exits stay in one OCA group."));
    }
    let foreign: Vec<String> = working.iter().filter(|d| d.order.client_id != ctx.client_id).map(|d| format!("#{}", d.order_id)).collect();
    if !foreign.is_empty() {
        return Err(invalid(format!(
            "Order(s) {} on this contract were placed by TWS or another API client. Cancel them there first; nothing was sent.",
            foreign.join(", ")
        )));
    }

    let mut cancelled: Vec<String> = Vec::new();
    for d in &working {
        if let Err(e) = cancel_confirmed(ctx.client, d).await {
            return Err(api(nothing_closed(&e, &cancelled)));
        }
        cancelled.push(format!("#{}", d.order_id));
    }

    if !working_orders(ctx.client, Some(contract_id)).await?.into_iter().filter(|d| d.order.account == ctx.account || d.order.account.is_empty()).collect::<Vec<_>>().is_empty() {
        return Err(api(nothing_closed(&"Working orders remain on the contract; review them before closing", &cancelled)));
    }
    let quantity = current_position(ctx.client, ctx.account, contract_id).await.map_err(|e| api(nothing_closed(&e, &cancelled)))?;
    if !quantity.is_finite() { return Err(invalid("IB returned an invalid position quantity; nothing was sent.")); }
    if quantity == 0.0 && limit_price.is_none() {
        return Ok(PlacedOrder { order_id: 0, status: "Flat".into(), message: "Position is already flat; no market order sent.".into() });
    }
    if let Some(expected) = expected_quantity {
        check_quantity(quantity, expected).map_err(|e| api(nothing_closed(&e, &cancelled)))?;
    }

    let action = if quantity > 0.0 { Action::Sell } else { Action::Buy };
    let mut order = match limit_price {
        Some(price) => order_builder::limit_order(action, quantity.abs(), tick(price, &resolved, if action == Action::Sell { Round::Down } else { Round::Up })),
        None => order_builder::market_order(action, quantity.abs()),
    };
    order.account = ctx.account.into();
    order.tif = ibapi::orders::TimeInForce::Day;
    let order_id = ctx.client.next_order_id();
    crate::orders::note_submit(order_id);
    let sub = ctx.client.place_order(order_id, &resolved.contract, &order).await?;
    let mut placed = await_ack(order_id, sub).await.map_err(|e| api(nothing_closed(&e, &cancelled)))?;
    if !cancelled.is_empty() {
        let note = format!("Cancelled {} first.", cancelled.join(", "));
        placed.message = if placed.message.is_empty() { note } else { format!("{note} {}", placed.message) };
    }
    Ok(placed)
}

/// Error text for an aborted close, including any exits that were already cancelled
/// (the position no longer has them).
fn nothing_closed(e: &dyn std::fmt::Display, cancelled: &[String]) -> String {
    if cancelled.is_empty() {
        format!("Not closed: {e}")
    } else {
        format!("Not closed: {e}. Orders {} were already cancelled, so the position has no exits now.", cancelled.join(", "))
    }
}

/// Puts a take-profit and/or stop on a position that has no working orders, sized from
/// IB's current quantity and joined in one OCA group so at most the position is sold.
pub(crate) async fn protect(
    ctx: Ctx<'_>,
    contract_id: i32,
    expected_quantity: f64,
    take_profit: Option<f64>,
    stop: Option<f64>,
    stop_limit: Option<f64>,
) -> Result<Vec<PlacedOrder>, IbkrError> {
    let long = expected_quantity > 0.0;
    validate_protection(long, take_profit, stop, stop_limit)?;
    let resolved = options::resolve_contract_id(ctx.client, contract_id).await?;
    if !working_orders(ctx.client, Some(contract_id)).await?.is_empty() {
        return Err(invalid("This position already has working orders. Edit those instead; nothing was sent."));
    }
    let quantity = current_position(ctx.client, ctx.account, contract_id).await?;
    check_quantity(quantity, expected_quantity)?;

    // Exits sell a long and buy back a short; round each price away from the market.
    let (action, out, back) = if long { (Action::Sell, Round::Up, Round::Down) } else { (Action::Buy, Round::Down, Round::Up) };
    let mut orders: Vec<(&str, Order)> = Vec::new();
    if let Some(tp) = take_profit {
        orders.push(("Take-profit", order_builder::limit_order(action, quantity.abs(), tick(tp, &resolved, out))));
    }
    if let Some(stop) = stop {
        let mut o = order_builder::stop(action, quantity.abs(), tick(stop, &resolved, back));
        if let Some(limit) = stop_limit {
            o.order_type = "STP LMT".into();
            o.limit_price = Some(tick(limit, &resolved, back));
        }
        orders.push(("Stop", o));
    }

    let oca = strategy::oca_group_name(0);
    let mut placed: Vec<PlacedOrder> = Vec::new();
    for (label, mut order) in orders {
        order.oca_group = oca.clone();
        order.oca_type = OcaType::ReduceWithBlock;
        order.tif = ibapi::orders::TimeInForce::GoodTillCanceled;
        order.transmit = true;
        let order_id = ctx.client.next_order_id();
        crate::orders::note_submit(order_id);
        let result = match ctx.client.place_order(order_id, &resolved.contract, &order).await {
            Ok(sub) => await_ack(order_id, sub).await,
            Err(e) => Err(e.into()),
        };
        match result {
            Ok(p) => placed.push(p),
            Err(e) if placed.is_empty() => return Err(e),
            Err(e) => {
                let working = placed.iter().map(|p| format!("#{}", p.order_id)).collect::<Vec<_>>().join(", ");
                return Err(api(format!("Order {working} is working, but the {} failed: {e}", label.to_lowercase())));
            }
        }
    }
    Ok(placed)
}

pub(crate) fn validate_protection(long: bool, take_profit: Option<f64>, stop: Option<f64>, stop_limit: Option<f64>) -> Result<(), IbkrError> {
    let positive = |v: f64| v.is_finite() && v > 0.0;
    if take_profit.is_none() && stop.is_none() {
        return Err(invalid("set a take-profit, a stop, or both"));
    }
    if take_profit.is_some_and(|p| !positive(p)) || stop.is_some_and(|p| !positive(p)) || stop_limit.is_some_and(|p| !positive(p)) {
        return Err(invalid("prices must be greater than 0"));
    }
    if stop_limit.is_some() && stop.is_none() {
        return Err(invalid("a stop limit needs a stop price"));
    }
    if let (Some(tp), Some(stop)) = (take_profit, stop)
        && (if long { tp <= stop } else { tp >= stop })
    {
        return Err(invalid(if long { "the take-profit must be above the stop" } else { "the take-profit must be below the stop" }));
    }
    if let (Some(stop), Some(limit)) = (stop, stop_limit)
        && (if long { limit > stop } else { limit < stop })
    {
        return Err(invalid(if long { "the stop limit must be at or below the stop" } else { "the stop limit must be at or above the stop" }));
    }
    Ok(())
}

/// Changes the limit and/or stop price of one of this connection's working orders. The
/// order is re-sent as IB currently holds it (so an OCA-reduced quantity stays reduced).
pub(crate) async fn modify(ctx: Ctx<'_>, order_id: i32, limit_price: Option<f64>, stop_price: Option<f64>) -> Result<PlacedOrder, IbkrError> {
    if limit_price.is_none() && stop_price.is_none() {
        return Err(invalid("nothing to change"));
    }
    if limit_price.into_iter().chain(stop_price).any(|p| !(p.is_finite() && p > 0.0)) {
        return Err(invalid("prices must be greater than 0"));
    }
    let d = working_orders(ctx.client, None)
        .await?
        .into_iter()
        .find(|d| d.order_id == order_id && d.order.client_id == ctx.client_id)
        .ok_or_else(|| invalid(format!("Order #{order_id} isn't working, or wasn't placed by this connection.")))?;
    let mut order: Order = d.order;
    if limit_price.is_some() && !order.order_type.contains("LMT") {
        return Err(invalid(format!("Order #{order_id} is {}; it has no limit price", order.order_type)));
    }
    if stop_price.is_some() && !order.order_type.contains("STP") {
        return Err(invalid(format!("Order #{order_id} is {}; it has no stop price", order.order_type)));
    }
    let resolved = options::resolve_contract_id(ctx.client, d.contract.contract_id).await?;
    if let Some(p) = limit_price {
        order.limit_price = Some(tick(p, &resolved, Round::Nearest));
    }
    if let Some(p) = stop_price {
        order.aux_price = Some(tick(p, &resolved, Round::Nearest));
    }
    order.transmit = true;

    let sub = ctx.client.place_order(order_id, &resolved.contract, &order).await?;
    await_ack(order_id, sub)
        .await
        .map_err(|e| api(format!("Change not applied: {e} The order keeps its previous price unless the Orders list shows otherwise.")))
}

/// Rounds to a valid tick for the contract, never below one tick.
fn tick(price: f64, c: &ResolvedContract, dir: Round) -> f64 {
    options::round_to_tick(price, &c.increments, dir).max(options::tick_at(0.0, &c.increments))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn close_review_rejects_nonfinite_quantities() {
        assert!(check_quantity(25.0, f64::NAN).is_err());
        assert!(check_quantity(f64::INFINITY, 25.0).is_err());
        assert!(check_quantity(-100.0, -100.0).is_ok());
    }

    #[test]
    fn protection_prices_must_bracket_the_position() {
        assert!(validate_protection(true, Some(12.0), Some(9.0), Some(8.9)).is_ok());
        assert!(validate_protection(true, None, None, None).is_err(), "nothing set");
        assert!(validate_protection(true, Some(9.0), Some(10.0), None).is_err(), "long TP below stop");
        assert!(validate_protection(true, None, Some(9.0), Some(9.5)).is_err(), "long stop limit above stop");
        assert!(validate_protection(true, None, None, Some(9.0)).is_err(), "limit without stop");
        assert!(validate_protection(false, Some(8.0), Some(11.0), Some(11.2)).is_ok(), "short");
        assert!(validate_protection(false, Some(12.0), Some(11.0), None).is_err(), "short TP above stop");
        assert!(validate_protection(true, Some(f64::NAN), None, None).is_err());
    }

    #[test]
    fn quantity_must_match_review() {
        assert!(check_quantity(5.0, 5.0).is_ok());
        assert!(check_quantity(0.0, 5.0).is_err(), "flat");
        assert!(check_quantity(3.0, 5.0).is_err(), "an exit filled meanwhile");
        assert!(check_quantity(-5.0, 5.0).is_err());
    }
}
