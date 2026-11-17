//! Account risk controls: a daily loss limit, a per-trade cost limit, and a halt (kill
//! switch) for the rest of the trading day.
//!
//! Safety rules (see CLAUDE.md):
//! - Only opening orders are checked. Exits (take-profit, stop, EOD, close-now, position
//!   close / protect / modify, cancels) never are: blocking an exit adds risk.
//! - A halt lasts until the US/Eastern trading day rolls over, and is saved per account so
//!   a restart doesn't lift it. Tightening a limit applies now; loosening one waits for
//!   the next trading day.
//! - Fail closed: with a daily loss limit set, entries wait for a current P&L reading from
//!   IB; a max-cost check with no price refuses the entry; live sessions refuse entries
//!   while the guard isn't running.
//! - Halting disarms strategies that haven't bought yet, cancels strategy entries in
//!   flight (via the `watch` channel) and cancels this client's working manual buys.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use ibapi::Client;
use ibapi::orders::Action;
use jiff::Zoned;
use tokio::sync::watch;

use crate::session::rt;
use crate::strategy::{self, OwnedOrders};
use crate::types::*;
use crate::position;

#[uniffi::export(with_foreign)]
pub trait RiskListener: Send + Sync {
    fn on_risk(&self, status: RiskStatus);
    fn on_error(&self, message: String);
}

// ---------------------------------------------------------------------------
// Pure logic (unit tested)
// ---------------------------------------------------------------------------

/// What's saved per account.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct RiskBook {
    /// "YYYYMMDD", US/Eastern.
    pub day: String,
    pub limits: RiskLimits,
    pub pending: Option<RiskLimits>,
    pub halted: Option<String>,
}

/// The stricter of two limits; None is "off", the loosest.
fn tighter(a: Option<f64>, b: Option<f64>) -> Option<f64> {
    match (a, b) {
        (Some(x), Some(y)) => Some(x.min(y)),
        (x, None) | (None, x) => x,
    }
}

fn money(v: f64) -> String {
    if v < 0.0 { format!("-${:.2}", -v) } else { format!("${v:.2}") }
}

impl RiskBook {
    pub(crate) fn new(day: &str) -> Self {
        RiskBook { day: day.to_string(), ..Default::default() }
    }

    /// A new trading day lifts the halt and applies pending (looser) limits. Returns
    /// whether anything changed.
    pub(crate) fn roll(&mut self, today: &str) -> bool {
        if self.day == today {
            return false;
        }
        self.day = today.to_string();
        self.halted = None;
        if let Some(pending) = self.pending.take() {
            self.limits = pending;
        }
        true
    }

    /// Tighter values apply now; anything looser than today's limits waits for tomorrow.
    pub(crate) fn set_limits(&mut self, wanted: RiskLimits) {
        let now = RiskLimits {
            max_daily_loss: tighter(self.limits.max_daily_loss, wanted.max_daily_loss),
            max_cost_per_trade: tighter(self.limits.max_cost_per_trade, wanted.max_cost_per_trade),
        };
        self.limits = now;
        self.pending = (wanted != now).then_some(wanted);
    }

    /// Returns true if this halted trading (it wasn't already halted).
    pub(crate) fn halt(&mut self, reason: String) -> bool {
        if self.halted.is_some() {
            return false;
        }
        self.halted = Some(reason);
        true
    }

    /// Halts when the day's P&L reaches the loss limit. Returns true if it just halted.
    pub(crate) fn check_pnl(&mut self, pnl: f64) -> bool {
        match self.limits.max_daily_loss {
            Some(max) if pnl <= -max => self.halt(format!("Daily loss limit reached: P&L {} (limit {})", money(pnl), money(-max))),
            _ => false,
        }
    }

    /// May an opening order go out? `cost` is its estimate (None = no price to estimate
    /// from), `pnl` the current daily P&L, `guarded` whether the guard may vouch for it.
    pub(crate) fn check_entry(&self, cost: Option<f64>, pnl: Option<f64>, guarded: bool) -> Result<(), String> {
        if let Some(reason) = &self.halted {
            return Err(format!("Trading is halted for today ({reason}). Exits still work."));
        }
        if !guarded {
            return Err("Risk controls aren't running, so opening orders are refused on live accounts.".into());
        }
        if let Some(max) = self.limits.max_daily_loss {
            match pnl {
                None => return Err("Waiting for IB's daily P&L; opening orders are paused until it arrives.".into()),
                Some(p) if p <= -max => return Err(format!("Daily loss limit reached: P&L {} (limit {}).", money(p), money(-max))),
                Some(_) => {}
            }
        }
        if let Some(max) = self.limits.max_cost_per_trade {
            match cost {
                None => return Err(format!("No price to check the cost against the max cost per trade ({}).", money(max))),
                Some(c) if c > max => return Err(format!("Estimated cost {} is above the max cost per trade ({}).", money(c), money(max))),
                Some(_) => {}
            }
        }
        Ok(())
    }
}

pub(crate) fn validate_limits(l: &RiskLimits) -> Result<(), IbkrError> {
    for (name, v) in [("max daily loss", l.max_daily_loss), ("max cost per trade", l.max_cost_per_trade)] {
        if let Some(v) = v
            && !(v.is_finite() && v > 0.0)
        {
            return Err(IbkrError::Invalid { message: format!("{name} must be greater than 0") });
        }
    }
    Ok(())
}

pub(crate) fn trading_day() -> String {
    Zoned::now().with_time_zone(strategy::eastern()).strftime("%Y%m%d").to_string()
}

// ---------------------------------------------------------------------------
// Guard
// ---------------------------------------------------------------------------

struct State {
    book: RiskBook,
    path: Option<PathBuf>,
    listener: Option<Arc<dyn RiskListener>>,
    pnl: Option<f64>,
    running: bool,
}

/// One per session. Strategies and `place_order` ask it before any opening order.
pub(crate) struct RiskGuard {
    client: Arc<Client>,
    client_id: i32,
    account: String,
    owned: OwnedOrders,
    /// Entries need the guard running (live port or a non-paper account).
    live: bool,
    state: Mutex<State>,
    /// The halt reason, for strategy tasks to react to.
    halt_tx: watch::Sender<Option<String>>,
}

impl RiskGuard {
    pub(crate) fn new(client: Arc<Client>, client_id: i32, account: String, owned: OwnedOrders, live: bool) -> Arc<Self> {
        let state = State { book: RiskBook::new(&trading_day()), path: None, listener: None, pnl: None, running: false };
        Arc::new(RiskGuard { client, client_id, account, owned, live, state: Mutex::new(state), halt_tx: watch::channel(None).0 })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Loads the saved state and starts reporting. An unreadable file halts trading for
    /// the day rather than silently dropping a halt.
    pub(crate) fn start(&self, path: PathBuf, listener: Arc<dyn RiskListener>) {
        let today = trading_day();
        let mut s = self.lock();
        let mut problem = None;
        s.book = match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|e| {
                problem = Some(format!("Couldn't read saved risk state ({e})"));
                RiskBook::new(&today)
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => RiskBook::new(&today),
            Err(e) => {
                problem = Some(format!("Couldn't read saved risk state ({e})"));
                RiskBook::new(&today)
            }
        };
        s.book.roll(&today);
        s.path = Some(path);
        s.listener = Some(listener);
        s.running = true;
        let halted = problem.is_some_and(|p| s.book.halt(p));
        self.commit(&mut s, halted);
    }

    /// The P&L stream task ended (cancelled, or the session closed).
    pub(crate) fn stop(&self) {
        let mut s = self.lock();
        s.running = false;
        s.pnl = None;
        if let Some(l) = &s.listener {
            l.on_risk(status(&s));
        }
        s.listener = None;
    }

    /// Saves, reports, and broadcasts the halt state; cancels manual buys on a new halt.
    fn commit(&self, s: &mut State, halted_now: bool) {
        if let Some(path) = &s.path
            && let Err(e) = save(path, &s.book)
            && let Some(l) = &s.listener
        {
            l.on_error(format!("Couldn't save risk state: {e}"));
        }
        if let Some(l) = &s.listener {
            l.on_risk(status(s));
        }
        self.halt_tx.send_replace(s.book.halted.clone());
        if halted_now {
            rt().spawn(cancel_manual_buys(self.client.clone(), self.client_id, self.account.clone(), self.owned.clone()));
        }
    }

    pub(crate) fn status(&self) -> RiskStatus {
        status(&self.lock())
    }

    pub(crate) fn subscribe_halt(&self) -> watch::Receiver<Option<String>> {
        self.halt_tx.subscribe()
    }

    pub(crate) fn halted(&self) -> Option<String> {
        let mut s = self.lock();
        self.roll(&mut s);
        s.book.halted.clone()
    }

    pub(crate) fn checks_cost(&self) -> bool {
        self.lock().book.limits.max_cost_per_trade.is_some()
    }

    fn roll(&self, s: &mut State) {
        if s.book.roll(&trading_day()) {
            self.commit(s, false);
        }
    }

    /// Called periodically so a halt lifts (and the UI updates) at the day boundary.
    pub(crate) fn tick(&self) {
        let mut s = self.lock();
        self.roll(&mut s);
    }

    pub(crate) fn set_limits(&self, limits: RiskLimits) -> Result<RiskStatus, IbkrError> {
        validate_limits(&limits)?;
        let mut s = self.lock();
        self.roll(&mut s);
        s.book.set_limits(limits);
        // A tighter loss limit may already be breached.
        let halted = s.pnl.is_some_and(|p| s.book.check_pnl(p));
        self.commit(&mut s, halted);
        Ok(status(&s))
    }

    pub(crate) fn halt(&self, reason: String) {
        let mut s = self.lock();
        self.roll(&mut s);
        let halted = s.book.halt(reason);
        self.commit(&mut s, halted);
    }

    /// A new P&L reading, or None when the stream is down.
    pub(crate) fn set_pnl(&self, pnl: Option<f64>) {
        let mut s = self.lock();
        self.roll(&mut s);
        if s.pnl == pnl {
            return;
        }
        s.pnl = pnl;
        let halted = pnl.is_some_and(|p| s.book.check_pnl(p));
        self.commit(&mut s, halted);
    }

    /// Call right before sending an opening order.
    pub(crate) fn check_entry(&self, cost: Option<f64>) -> Result<(), IbkrError> {
        let mut s = self.lock();
        self.roll(&mut s);
        let guarded = s.running || !self.live;
        s.book.check_entry(cost, s.pnl, guarded).map_err(|message| IbkrError::Invalid { message })
    }
}

fn status(s: &State) -> RiskStatus {
    RiskStatus {
        trading_day: s.book.day.clone(),
        limits: s.book.limits,
        pending: s.book.pending,
        halted: s.book.halted.clone(),
        daily_pnl: s.pnl,
        running: s.running,
    }
}

/// Write-then-rename, so a crash never leaves a half-written file.
fn save(path: &Path, book: &RiskBook) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(book)?)?;
    std::fs::rename(tmp, path)
}

/// This client's working buy orders that no strategy owns (strategies cancel their own
/// entries). Orders from TWS or other clients can't be cancelled by this connection.
/// Cancels this client's working buys that could open or add to a position. Buys that
/// only cover a short (a buy-to-close, or a stop / take-profit on a short) are exits and
/// stay working. If positions can't be read, every manual buy is cancelled.
async fn cancel_manual_buys(client: Arc<Client>, client_id: i32, account: String, owned: OwnedOrders) {
    let Ok(working) = position::working_orders(&client, None).await else { return };
    let held = position::all_positions(&client, &account).await.unwrap_or_default();
    let owned: Vec<i32> = owned.lock().unwrap_or_else(|e| e.into_inner()).iter().copied().collect();
    let buys: Vec<(i32, i32, f64)> = working
        .iter()
        .filter(|d| d.order.client_id == client_id && d.order.action == Action::Buy && !owned.contains(&d.order_id))
        .filter(|d| d.order.account == account || d.order.account.is_empty())
        .map(|d| (d.order_id, d.contract.contract_id, (d.order.total_quantity - d.order.filled_quantity).max(0.0)))
        .collect();
    for id in buys_to_cancel(&buys, &held) {
        let _ = client.cancel_order(id, "").await;
    }
}

/// `buys` is (order id, contract id, remaining quantity). Per contract, buys are kept while
/// together they fit inside the short position; any buy beyond that is cancelled.
pub(crate) fn buys_to_cancel(buys: &[(i32, i32, f64)], held: &std::collections::HashMap<i32, f64>) -> Vec<i32> {
    let mut cover: std::collections::HashMap<i32, f64> = held.iter().map(|(c, q)| (*c, (-q).max(0.0))).collect();
    let mut out = Vec::new();
    for &(id, contract, remaining) in buys {
        let room = cover.entry(contract).or_insert(0.0);
        if remaining > 0.0 && remaining <= *room + 1e-9 {
            *room -= remaining;
        } else {
            out.push(id);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn halt_keeps_buys_that_only_cover_shorts() {
        let held = std::collections::HashMap::from([(1, -100.0), (2, 50.0)]);
        // Contract 1 is short 100: a 60 stop + 40 take-profit cover it; a further 10 would open.
        // Contract 2 is long, contract 3 flat: any buy adds risk.
        let buys = [(10, 1, 60.0), (11, 1, 40.0), (12, 1, 10.0), (13, 2, 5.0), (14, 3, 1.0)];
        assert_eq!(buys_to_cancel(&buys, &held), vec![12, 13, 14]);
        assert_eq!(buys_to_cancel(&[(15, 1, 150.0)], &held), vec![15], "flips the short to long");
    }

    fn limits(loss: Option<f64>, cost: Option<f64>) -> RiskLimits {
        RiskLimits { max_daily_loss: loss, max_cost_per_trade: cost }
    }

    #[test]
    fn tightening_applies_now_loosening_waits() {
        let mut b = RiskBook::new("20261022");
        b.set_limits(limits(Some(500.0), Some(1000.0)));
        assert_eq!(b.limits, limits(Some(500.0), Some(1000.0)), "from off, any limit is tighter");
        assert_eq!(b.pending, None);

        b.set_limits(limits(Some(800.0), Some(600.0)));
        assert_eq!(b.limits, limits(Some(500.0), Some(600.0)), "only the tighter field applies");
        assert_eq!(b.pending, Some(limits(Some(800.0), Some(600.0))));

        b.set_limits(limits(None, Some(600.0)));
        assert_eq!(b.limits.max_daily_loss, Some(500.0), "turning a limit off is loosening");

        assert!(b.roll("20261023"));
        assert_eq!(b.limits, limits(None, Some(600.0)));
        assert_eq!(b.pending, None);
        assert!(!b.roll("20261023"));
    }

    #[test]
    fn halt_lasts_until_the_day_rolls() {
        let mut b = RiskBook::new("20261022");
        assert!(b.halt("manual".into()));
        assert!(!b.halt("again".into()), "keeps the first reason");
        assert!(b.check_entry(Some(1.0), Some(0.0), true).unwrap_err().contains("manual"));
        b.roll("20261023");
        assert_eq!(b.halted, None);
        assert!(b.check_entry(Some(1.0), Some(0.0), true).is_ok());
    }

    #[test]
    fn daily_loss_halts_at_the_limit() {
        let mut b = RiskBook::new("20261022");
        b.set_limits(limits(Some(500.0), None));
        assert!(!b.check_pnl(-499.99));
        assert!(b.check_pnl(-500.0));
        assert!(b.halted.as_deref().unwrap().contains("-$500.00"));
        assert!(!b.check_pnl(-900.0), "already halted");
    }

    #[test]
    fn entries_fail_closed() {
        let mut b = RiskBook::new("20261022");
        assert!(b.check_entry(None, None, true).is_ok(), "no limits, nothing to check");
        assert!(b.check_entry(None, None, false).is_err(), "live without the guard");

        b.set_limits(limits(Some(500.0), Some(1000.0)));
        assert!(b.check_entry(Some(10.0), None, true).unwrap_err().contains("Waiting"), "no P&L yet");
        assert!(b.check_entry(Some(10.0), Some(-500.0), true).is_err());
        assert!(b.check_entry(None, Some(0.0), true).unwrap_err().contains("No price"));
        assert!(b.check_entry(Some(1000.01), Some(0.0), true).unwrap_err().contains("above"));
        assert!(b.check_entry(Some(1000.0), Some(0.0), true).is_ok());
    }

    #[test]
    fn validates_limits() {
        assert!(validate_limits(&limits(Some(1.0), None)).is_ok());
        assert!(validate_limits(&limits(Some(0.0), None)).is_err());
        assert!(validate_limits(&limits(None, Some(f64::NAN))).is_err());
    }

    #[test]
    fn book_round_trips() {
        let mut b = RiskBook::new("20261022");
        b.set_limits(limits(Some(500.0), None));
        b.halt("manual".into());
        let text = serde_json::to_string(&b).unwrap();
        assert_eq!(serde_json::from_str::<RiskBook>(&text).unwrap(), b);
    }
}
