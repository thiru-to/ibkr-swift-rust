//! Order blotter: every order IB reports this session (working orders plus today's
//! completed ones), keyed by permanent id and tagged with a status group.

use std::cmp::Reverse;
use std::collections::BTreeMap;
use std::time::Duration;

use futures::StreamExt;
use ibapi::Client;
use ibapi::orders::{OrderData, OrderStatus, OrderStatusKind, OrderUpdate, Orders};
use ibapi::subscriptions::{Subscription, SubscriptionItemStreamExt};

use crate::session::OrdersListener;
use crate::types::*;

pub(crate) fn group(status: &OrderStatusKind) -> OrderStatusGroup {
    use OrderStatusKind::*;
    match status {
        ApiPending | PendingSubmit | PreSubmitted | Submitted | PendingCancel => OrderStatusGroup::Open,
        Filled => OrderStatusGroup::Filled,
        Cancelled | ApiCancelled => OrderStatusGroup::Cancelled,
        Inactive => OrderStatusGroup::Inactive,
        Unknown(_) => OrderStatusGroup::Other,
    }
}

fn positive(v: Option<f64>) -> Option<f64> {
    v.filter(|p| p.is_finite() && *p > 0.0)
}

/// Orders keyed by perm id, which is unique across clients and sessions (completed
/// orders placed outside the API often have order id 0). An order seen before IB assigns
/// a perm id is keyed by its negated order id until the perm id arrives.
#[derive(Default)]
pub(crate) struct Book {
    orders: BTreeMap<i64, OrderInfo>,
}

impl Book {
    fn key(&mut self, perm_id: i64, order_id: i32) -> i64 {
        let provisional = -(order_id as i64);
        if perm_id == 0 {
            return provisional;
        }
        if let Some(mut o) = self.orders.remove(&provisional) {
            o.perm_id = perm_id;
            self.orders.insert(perm_id, o);
        }
        perm_id
    }

    pub(crate) fn upsert(&mut self, d: OrderData) {
        let key = self.key(d.order.perm_id, d.order_id);
        let prev = self.orders.get(&key);
        let state = &d.order_state;
        let detail = [&state.completed_status, &state.reject_reason, &state.warning_text]
            .into_iter()
            .find(|s| !s.is_empty())
            .cloned()
            .or_else(|| prev.map(|p| p.detail.clone()))
            .unwrap_or_default();
        let info = OrderInfo {
            order_id: d.order_id,
            perm_id: d.order.perm_id,
            account: d.order.account.clone(),
            symbol: d.contract.symbol.to_string(),
            local_symbol: d.contract.local_symbol.clone(),
            sec_type: d.contract.security_type.to_string(),
            action: format!("{:?}", d.order.action),
            order_type: d.order.order_type.clone(),
            tif: format!("{:?}", d.order.tif),
            // Completed orders report total_quantity 0 once filled.
            quantity: d.order.total_quantity.max(d.order.filled_quantity),
            filled: prev.map_or(0.0, |p| p.filled).max(d.order.filled_quantity),
            // IB reports 0 for "not set", and can echo stale prices on other order types.
            limit_price: positive(d.order.limit_price).filter(|_| d.order.order_type.contains("LMT")),
            stop_price: positive(d.order.aux_price).filter(|_| d.order.order_type.contains("STP")),
            average_fill_price: prev.and_then(|p| p.average_fill_price),
            status: state.status.as_str().to_string(),
            group: group(&state.status),
            detail,
            completed_time: state.completed_time.clone(),
        };
        self.orders.insert(key, info);
    }

    pub(crate) fn apply_status(&mut self, s: OrderStatus) {
        let key = self.key(s.perm_id, s.order_id);
        // A status before its OpenOrder message is skipped; the OpenOrder follows.
        if let Some(o) = self.orders.get_mut(&key) {
            o.status = s.status.as_str().to_string();
            o.group = group(&s.status);
            o.filled = s.filled;
            if let Some(p) = positive(s.average_fill_price) {
                o.average_fill_price = Some(p);
            }
            if !s.why_held.is_empty() {
                o.detail = s.why_held;
            }
        }
    }

    /// Newest first: orders still waiting for a perm id, then by perm id descending.
    pub(crate) fn snapshot(&self) -> Vec<OrderInfo> {
        let mut orders: Vec<OrderInfo> = self.orders.values().cloned().collect();
        orders.sort_by_key(|o| Reverse((o.perm_id == 0, o.perm_id, o.order_id)));
        orders
    }
}

async fn seed(book: &mut Book, sub: Subscription<Orders>) {
    let mut sub = sub.filter_data();
    let read = async {
        while let Some(Ok(item)) = sub.next().await {
            match item {
                Orders::OrderData(d) => book.upsert(d),
                Orders::OrderStatus(s) => book.apply_status(s),
            }
        }
    };
    let _ = tokio::time::timeout(Duration::from_secs(5), read).await;
}

pub(crate) async fn stream_orders(client: &Client, listener: &dyn OrdersListener) -> Result<(), IbkrError> {
    // Open the live stream first so nothing placed during seeding is missed.
    let updates = client.order_update_stream().await?;
    let mut book = Book::default();

    seed(&mut book, client.all_open_orders().await?).await;
    // Today's filled / cancelled / rejected orders, including ones placed outside the API.
    seed(&mut book, client.completed_orders(false).await?).await;
    listener.on_orders(book.snapshot());

    let mut updates = updates.filter_data();
    while let Some(item) = updates.next().await {
        match item? {
            OrderUpdate::OpenOrder(d) => book.upsert(d),
            OrderUpdate::OrderStatus(s) => book.apply_status(s),
            _ => continue,
        }
        listener.on_orders(book.snapshot());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data(order_id: i32, perm_id: i64, status: OrderStatusKind) -> OrderData {
        let mut d = OrderData { order_id, contract: Default::default(), order: Default::default(), order_state: Default::default() };
        d.order.perm_id = perm_id;
        d.order.total_quantity = 1.0;
        d.order_state.status = status;
        d
    }

    fn status(order_id: i32, perm_id: i64, status: OrderStatusKind, filled: f64) -> OrderStatus {
        OrderStatus { order_id, perm_id, status, filled, average_fill_price: Some(1.5), ..Default::default() }
    }

    #[test]
    fn groups_statuses() {
        assert_eq!(group(&OrderStatusKind::PreSubmitted), OrderStatusGroup::Open);
        assert_eq!(group(&OrderStatusKind::PendingCancel), OrderStatusGroup::Open);
        assert_eq!(group(&OrderStatusKind::Filled), OrderStatusGroup::Filled);
        assert_eq!(group(&OrderStatusKind::ApiCancelled), OrderStatusGroup::Cancelled);
        assert_eq!(group(&OrderStatusKind::Inactive), OrderStatusGroup::Inactive);
        assert_eq!(group(&OrderStatusKind::Unknown("Weird".into())), OrderStatusGroup::Other);
    }

    #[test]
    fn keeps_terminal_orders_and_tracks_fills() {
        let mut book = Book::default();
        book.upsert(data(5, 100, OrderStatusKind::Submitted));
        book.apply_status(status(5, 100, OrderStatusKind::Filled, 1.0));
        let o = &book.snapshot()[0];
        assert_eq!((o.group, o.status.as_str(), o.filled, o.average_fill_price), (OrderStatusGroup::Filled, "Filled", 1.0, Some(1.5)));
    }

    #[test]
    fn manual_orders_with_id_zero_do_not_collide() {
        let mut book = Book::default();
        book.upsert(data(0, 100, OrderStatusKind::Cancelled));
        book.upsert(data(0, 200, OrderStatusKind::Filled));
        assert_eq!(book.snapshot().len(), 2);
    }

    #[test]
    fn provisional_key_migrates_to_perm_id() {
        let mut book = Book::default();
        book.upsert(data(7, 0, OrderStatusKind::PendingSubmit));
        book.apply_status(status(7, 300, OrderStatusKind::Submitted, 0.0));
        book.upsert(data(7, 300, OrderStatusKind::Submitted));
        let snap = book.snapshot();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].perm_id, 300);
    }

    #[test]
    fn newest_first() {
        let mut book = Book::default();
        book.upsert(data(1, 100, OrderStatusKind::Filled));
        book.upsert(data(2, 200, OrderStatusKind::Submitted));
        book.upsert(data(3, 0, OrderStatusKind::PendingSubmit));
        let ids: Vec<i32> = book.snapshot().iter().map(|o| o.order_id).collect();
        assert_eq!(ids, vec![3, 2, 1]);
    }
}
