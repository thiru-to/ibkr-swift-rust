//! Order blotter: every order IB reports this session (working orders plus today's
//! completed ones), keyed by permanent id and tagged with a status group.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures::StreamExt;
use ibapi::Client;
use ibapi::orders::{Execution, ExecutionFilter, Executions, OrderData, OrderStatus, OrderStatusKind, OrderUpdate, Orders};
use ibapi::subscriptions::{Subscription, SubscriptionItem, SubscriptionItemStreamExt};

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

/// System clock, unix milliseconds.
pub(crate) fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// When this process sent each order id (order ids are unique per client and session).
fn submits() -> &'static Mutex<HashMap<i32, i64>> {
    static SUBMITS: OnceLock<Mutex<HashMap<i32, i64>>> = OnceLock::new();
    SUBMITS.get_or_init(Default::default)
}

/// Call right before `client.place_order` for a new order. A later re-send of the same id
/// (a price change) keeps the original time.
pub(crate) fn note_submit(order_id: i32) {
    submits().lock().unwrap_or_else(|e| e.into_inner()).entry(order_id).or_insert_with(now_ms);
}

/// Timelines and executions by perm id, kept across order-book reloads (Refresh, Gateway
/// reconnects) so live timings aren't replaced by "loaded at connect".
#[derive(Default)]
struct Memory {
    timelines: HashMap<i64, OrderTimeline>,
    executions: HashMap<i64, Vec<OrderExecution>>,
}

fn memory() -> &'static Mutex<Memory> {
    static MEMORY: OnceLock<Mutex<Memory>> = OnceLock::new();
    MEMORY.get_or_init(Default::default)
}

fn remembered(perm_id: i64) -> Option<OrderTimeline> {
    (perm_id != 0).then(|| memory().lock().unwrap_or_else(|e| e.into_inner()).timelines.get(&perm_id).cloned()).flatten()
}

fn submitted_at(order_id: i32) -> Option<i64> {
    submits().lock().unwrap_or_else(|e| e.into_inner()).get(&order_id).copied()
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
    /// This connection's client id: IB's order-bound messages carry only an order id.
    client_id: i32,
    /// IB messages (rejection reasons, warnings) for orders not seen yet, by order id.
    notes: HashMap<i32, String>,
    /// A status that arrived before its order, by key, with when it arrived.
    early: HashMap<i64, (OrderStatus, i64)>,
    /// (cumulative qty, average price) from executions, by perm id. Completed orders
    /// carry no fill price of their own.
    fills: HashMap<i64, (f64, f64)>,
    /// Executions by perm id, oldest first.
    executions: HashMap<i64, Vec<OrderExecution>>,
    /// Seeding is done: events now arrive as they happen.
    live: bool,
}

impl Book {
    pub(crate) fn new(client_id: i32) -> Self {
        let executions = memory().lock().unwrap_or_else(|e| e.into_inner()).executions.clone();
        Book { client_id, executions, ..Default::default() }
    }

    /// Saves timings so a reloaded book keeps them.
    fn remember(&self) {
        let mut m = memory().lock().unwrap_or_else(|e| e.into_inner());
        for o in self.orders.values().filter(|o| o.perm_id != 0) {
            m.timelines.insert(o.perm_id, o.timeline.clone());
        }
        for (perm, list) in &self.executions {
            m.executions.insert(*perm, list.clone());
        }
    }

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

    /// Events from here on are timed as they happen.
    pub(crate) fn go_live(&mut self) {
        self.live = true;
    }

    pub(crate) fn upsert(&mut self, d: OrderData) {
        self.upsert_at(d, now_ms());
    }

    fn upsert_at(&mut self, d: OrderData, at: i64) {
        let key = self.key(d.order.perm_id, d.order_id);
        let note = if d.order.client_id == self.client_id { self.notes.remove(&d.order_id) } else { None };
        let prev = self.orders.get(&key);
        let state = &d.order_state;
        let detail = [&state.completed_status, &state.reject_reason, &state.warning_text]
            .into_iter()
            .find(|s| !s.is_empty())
            .cloned()
            .or(note)
            .or_else(|| prev.map(|p| p.detail.clone()))
            .unwrap_or_default();
        let info = OrderInfo {
            order_id: d.order_id,
            perm_id: d.order.perm_id,
            client_id: d.order.client_id,
            contract_id: d.contract.contract_id,
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
            average_fill_price: prev
                .and_then(|p| p.average_fill_price)
                .or_else(|| self.fills.get(&d.order.perm_id).map(|f| f.1)),
            status: state.status.as_str().to_string(),
            group: group(&state.status),
            detail,
            completed_time: state.completed_time.clone(),
            timeline: prev.map(|p| p.timeline.clone()).or_else(|| remembered(d.order.perm_id)).unwrap_or_else(|| OrderTimeline {
                submitted_ms: (d.order.client_id == self.client_id).then(|| submitted_at(d.order_id)).flatten(),
                first_seen_ms: at,
                from_snapshot: !self.live,
                ..Default::default()
            }),
            executions: Vec::new(),
        };
        let filled = info.filled;
        self.orders.insert(key, info);
        let early = self.early.remove(&key);
        // A status that beat its OpenOrder is the earlier event, so time it first.
        if let Some((e, early_at)) = &early {
            self.mark(key, e.status.as_str(), &e.status, e.filled, *early_at);
        }
        self.mark(key, state.status.as_str(), &state.status, filled, at);
        if let Some((s, at)) = early {
            self.apply_status_at(s, at);
        }
    }

    /// Times an IB message about the order. Orders loaded at connect have no live
    /// history: their acknowledgement and fills happened before the app was watching.
    fn mark(&mut self, key: i64, status: &str, kind: &OrderStatusKind, filled: f64, at: i64) {
        let live = self.live;
        let Some(t) = self.orders.get_mut(&key).map(|o| &mut o.timeline) else { return };
        if !live && t.from_snapshot {
            return;
        }
        // An order loaded at connect was acknowledged before the app saw it.
        if t.ack_ms.is_none() && !t.from_snapshot {
            t.ack_ms = Some(at);
            t.ack_status = status.to_string();
        }
        if filled > 0.0 && t.first_fill_ms.is_none() {
            t.first_fill_ms = Some(at);
        }
        match kind {
            OrderStatusKind::Filled if t.filled_ms.is_none() => t.filled_ms = Some(at),
            OrderStatusKind::Cancelled | OrderStatusKind::ApiCancelled | OrderStatusKind::Inactive if t.ended_ms.is_none() => {
                t.ended_ms = Some(at)
            }
            _ => {}
        }
    }

    pub(crate) fn apply_status(&mut self, s: OrderStatus) {
        self.apply_status_at(s, now_ms());
    }

    fn apply_status_at(&mut self, s: OrderStatus, at: i64) {
        let key = self.key(s.perm_id, s.order_id);
        if !self.orders.contains_key(&key) {
            // Held until its OpenOrder arrives.
            self.early.insert(key, (s, at));
            return;
        }
        self.mark(key, s.status.as_str(), &s.status, s.filled, at);
        let Some(o) = self.orders.get_mut(&key) else { return };
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

    /// An IB message bound to one of this client's orders, e.g. "[201] Order rejected - …".
    /// IB may send it without ever sending the order itself.
    pub(crate) fn note(&mut self, order_id: i32, message: String) {
        let own = self.client_id;
        match self.orders.values_mut().find(|o| o.order_id == order_id && o.client_id == own) {
            Some(o) => o.detail = message,
            None => {
                self.notes.insert(order_id, message);
            }
        }
    }

    /// Executions carry the running average price for their order.
    pub(crate) fn apply_execution(&mut self, e: &Execution) {
        self.apply_execution_at(e, now_ms());
    }

    fn apply_execution_at(&mut self, e: &Execution, at: i64) {
        if e.perm_id == 0 || !(e.average_price.is_finite() && e.average_price > 0.0) {
            return;
        }
        let list = self.executions.entry(e.perm_id).or_default();
        if !list.iter().any(|x| x.exec_id == e.execution_id) {
            list.push(OrderExecution {
                exec_id: e.execution_id.clone(),
                ib_time: e.time.clone(),
                received_ms: at,
                from_snapshot: !self.live,
                shares: e.shares,
                price: e.price,
                exchange: e.exchange.clone(),
            });
            // A live execution can beat the status that reports the fill.
            let live = self.live;
            if let Some(t) = self.orders.get_mut(&e.perm_id).map(|o| &mut o.timeline)
                && live
                && t.first_fill_ms.is_none_or(|f| at < f)
            {
                t.first_fill_ms = Some(at);
            }
        }
        let fill = self.fills.entry(e.perm_id).or_insert((0.0, 0.0));
        // Executions can arrive out of order; the largest cumulative quantity is the latest.
        if e.cumulative_quantity < fill.0 {
            return;
        }
        *fill = (e.cumulative_quantity, e.average_price);
        if let Some(o) = self.orders.get_mut(&e.perm_id) {
            o.average_fill_price = Some(e.average_price);
            o.filled = o.filled.max(e.cumulative_quantity);
        }
    }

    /// Newest first: orders still waiting for a perm id, then by perm id descending.
    pub(crate) fn snapshot(&self) -> Vec<OrderInfo> {
        self.remember();
        let mut orders: Vec<OrderInfo> = self
            .orders
            .values()
            .map(|o| {
                let mut o = o.clone();
                o.executions = self.executions.get(&o.perm_id).cloned().unwrap_or_default();
                o
            })
            .collect();
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

/// Today's executions, for the fill prices of completed orders.
async fn seed_fills(book: &mut Book, sub: Subscription<Executions>) {
    let mut sub = sub.filter_data();
    let read = async {
        while let Some(Ok(item)) = sub.next().await {
            if let Executions::ExecutionData(d) = item {
                book.apply_execution(&d.execution);
            }
        }
    };
    let _ = tokio::time::timeout(Duration::from_secs(5), read).await;
}

pub(crate) async fn stream_orders(client: &Client, listener: &dyn OrdersListener, client_id: i32) -> Result<(), IbkrError> {
    // Open the live stream first so nothing placed during seeding is missed.
    let mut updates = client.order_update_stream().await?;
    let mut book = Book::new(client_id);

    seed(&mut book, client.all_open_orders().await?).await;
    // Today's filled / cancelled / rejected orders, including ones placed outside the API.
    seed(&mut book, client.completed_orders(false).await?).await;
    // Fill prices are best-effort; the list is still right without them.
    if let Ok(sub) = client.executions(ExecutionFilter::default()).await {
        seed_fills(&mut book, sub).await;
    }
    book.go_live();
    listener.on_orders(book.snapshot());

    // Not `filter_data()`: order-bound notices carry IB's rejection reasons.
    while let Some(item) = updates.next().await {
        match item? {
            SubscriptionItem::Data(OrderUpdate::OpenOrder(d)) => book.upsert(d),
            SubscriptionItem::Data(OrderUpdate::OrderStatus(s)) => book.apply_status(s),
            SubscriptionItem::Data(OrderUpdate::ExecutionData(d)) => book.apply_execution(&d.execution),
            SubscriptionItem::Notice(n) if !n.is_cancellation() => match n.request_id {
                Some(order_id) => book.note(order_id, n.to_string()),
                None => continue,
            },
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

    fn exec(perm_id: i64, id: &str, cum: f64) -> Execution {
        Execution {
            perm_id,
            execution_id: id.into(),
            time: "20261116 10:23:45 US/Eastern".into(),
            shares: 1.0,
            price: 1.5,
            cumulative_quantity: cum,
            average_price: 1.5,
            ..Default::default()
        }
    }

    #[test]
    fn live_orders_get_a_timeline() {
        let mut book = Book::new(0);
        book.go_live();
        note_submit(9001);
        let submitted = submitted_at(9001).unwrap();
        book.upsert_at(data(9001, 50, OrderStatusKind::PreSubmitted), submitted + 40);
        book.apply_status_at(status(9001, 50, OrderStatusKind::Submitted, 0.0), submitted + 45);
        book.apply_execution_at(&exec(50, "e.01", 1.0), submitted + 300);
        book.apply_status_at(status(9001, 50, OrderStatusKind::Filled, 1.0), submitted + 310);
        book.apply_execution_at(&exec(50, "e.01", 1.0), submitted + 900); // repeat
        let o = &book.snapshot()[0];
        let t = &o.timeline;
        assert_eq!(t.submitted_ms, Some(submitted));
        assert_eq!(t.ack_ms, Some(submitted + 40));
        assert_eq!(t.ack_status, "PreSubmitted");
        assert_eq!(t.first_fill_ms, Some(submitted + 300)); // the execution beat the status
        assert_eq!(t.filled_ms, Some(submitted + 310));
        assert!(!t.from_snapshot);
        assert_eq!(o.executions.len(), 1);
        assert_eq!(o.executions[0].ib_time, "20261116 10:23:45 US/Eastern");
        assert_eq!(o.executions[0].received_ms, submitted + 300);
    }

    #[test]
    fn loaded_orders_have_no_live_history() {
        let mut book = Book::new(0);
        book.upsert_at(data(1, 60, OrderStatusKind::Submitted), 1_000);
        book.apply_execution_at(&exec(60, "x.01", 1.0), 1_001);
        book.go_live();
        // Its later fill is seen live; its ack was before the app was watching.
        book.apply_status_at(status(1, 60, OrderStatusKind::Filled, 1.0), 5_000);
        let o = &book.snapshot()[0];
        assert!(o.timeline.from_snapshot);
        assert_eq!(o.timeline.first_seen_ms, 1_000);
        assert_eq!(o.timeline.ack_ms, None);
        assert_eq!(o.timeline.filled_ms, Some(5_000));
        assert!(o.executions[0].from_snapshot);
    }

    #[test]
    fn timings_survive_a_reload() {
        let mut book = Book::new(0);
        book.go_live();
        book.upsert_at(data(3, 80, OrderStatusKind::Submitted), 200);
        book.apply_execution_at(&exec(80, "r.01", 1.0), 250);
        let _ = book.snapshot();
        // Refresh: a new book loads the same order from IB's snapshot.
        let mut reloaded = Book::new(0);
        reloaded.upsert_at(data(3, 80, OrderStatusKind::Submitted), 9_000);
        reloaded.apply_execution_at(&exec(80, "r.01", 1.0), 9_001);
        let o = &reloaded.snapshot()[0];
        assert!(!o.timeline.from_snapshot);
        assert_eq!(o.timeline.ack_ms, Some(200));
        assert_eq!(o.executions.len(), 1);
        assert_eq!(o.executions[0].received_ms, 250);
    }

    #[test]
    fn early_status_keeps_its_arrival_time() {
        let mut book = Book::new(0);
        book.go_live();
        book.apply_status_at(status(2, 70, OrderStatusKind::Submitted, 0.0), 100);
        book.upsert_at(data(2, 70, OrderStatusKind::Submitted), 150);
        let t = &book.snapshot()[0].timeline;
        assert_eq!(t.first_seen_ms, 150);
        // The status arrived first, so it's the acknowledgement.
        assert_eq!(t.ack_ms, Some(100));
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
    fn status_before_order_is_applied_when_the_order_arrives() {
        let mut book = Book::default();
        book.apply_status(status(9, 400, OrderStatusKind::Filled, 1.0));
        book.upsert(data(9, 400, OrderStatusKind::Submitted));
        let o = &book.snapshot()[0];
        assert_eq!((o.group, o.average_fill_price), (OrderStatusGroup::Filled, Some(1.5)));
    }

    #[test]
    fn rejection_notes_attach_to_own_orders_only() {
        let mut book = Book::new(1);
        // Arrives before the order (IB often sends the error first).
        book.note(4, "[201] Order rejected".into());
        let mut foreign = data(4, 500, OrderStatusKind::Submitted);
        foreign.order.client_id = 2;
        book.upsert(foreign);
        let mut own = data(4, 600, OrderStatusKind::Inactive);
        own.order.client_id = 1;
        book.upsert(own);
        let snap = book.snapshot();
        assert_eq!(snap.iter().find(|o| o.perm_id == 600).unwrap().detail, "[201] Order rejected");
        assert_eq!(snap.iter().find(|o| o.perm_id == 500).unwrap().detail, "");
    }

    #[test]
    fn executions_fill_in_average_price() {
        let mut book = Book::default();
        let exec = |cum: f64, avg: f64| Execution { perm_id: 700, cumulative_quantity: cum, average_price: avg, ..Default::default() };
        book.apply_execution(&exec(2.0, 10.25));
        book.apply_execution(&exec(1.0, 10.00)); // older, arrives late
        let mut d = data(0, 700, OrderStatusKind::Filled);
        d.order.total_quantity = 0.0;
        d.order.filled_quantity = 2.0;
        book.upsert(d);
        let o = &book.snapshot()[0];
        assert_eq!((o.filled, o.quantity, o.average_fill_price), (2.0, 2.0, Some(10.25)));
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
