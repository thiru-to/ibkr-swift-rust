//! Realized P&L ledger: every fill and its commission, per account, saved locally.
//!
//! IB's API only returns about the last 7 days of executions, so the ledger keeps its own
//! history (`Application Support/Ledger/<account>.json`, passed in by Swift) to cover a
//! month or a year. Each run backfills IB's last 7 days, then polls today's executions.
//! Tallies use IB's realized P&L per closing fill, which is already net of the
//! commissions on both legs. Periods are US/Eastern calendar days.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use futures::StreamExt;
use ibapi::Client;
use ibapi::orders::{CommissionReport, ExecutionData, ExecutionFilter, ExecutionSide, Executions};
use ibapi::subscriptions::SubscriptionItemStreamExt;
use jiff::civil::{Date, DateTime};
use jiff::tz::TimeZone;
use jiff::{ToSpan, Zoned};
use serde::{Deserialize, Serialize};

use crate::strategy;
use crate::types::{LedgerSnapshot, PnlPeriod, PnlTally};

/// IB keeps executions this many days back (the API's maximum).
const BACKFILL_DAYS: i32 = 7;
const POLL: Duration = Duration::from_secs(10);
/// IB sends Double.MAX for "no value".
const NO_VALUE: f64 = 1e300;

#[uniffi::export(with_foreign)]
pub trait LedgerListener: Send + Sync {
    fn on_ledger(&self, snapshot: LedgerSnapshot);
    fn on_error(&self, message: String);
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct Fill {
    pub exec_id: String,
    /// US/Eastern trading day, "YYYYMMDD".
    pub day: String,
    pub local_symbol: String,
    pub sec_type: String,
    pub bought: bool,
    pub shares: f64,
    pub price: f64,
    pub commission: Option<f64>,
    /// IB's realized P&L, net of commissions; None on opening fills.
    pub realized_pnl: Option<f64>,
}

/// Commission report fields, kept until (or after) their execution arrives.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub(crate) struct Charge {
    pub commission: f64,
    pub realized_pnl: Option<f64>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub(crate) struct Ledger {
    /// Keyed by exec id without its correction suffix (".01", ".02"…).
    fills: BTreeMap<String, Fill>,
    /// By full exec id.
    charges: BTreeMap<String, Charge>,
    /// Fills are complete from this day, "YYYYMMDD".
    since: Option<String>,
    /// Last day whose executions were read, "YYYYMMDD".
    #[serde(default)]
    covered_through: Option<String>,
}

/// "0000e0d5.6543b2c1.01.01" → "0000e0d5.6543b2c1.01": a correction differs only after the last period.
fn base_id(exec_id: &str) -> &str {
    exec_id.rsplit_once('.').map_or(exec_id, |(base, _)| base)
}

fn value(v: Option<f64>) -> Option<f64> {
    v.filter(|v| v.is_finite() && v.abs() < NO_VALUE)
}

impl Ledger {
    /// Returns whether anything changed.
    pub fn add_fill(&mut self, mut fill: Fill) -> bool {
        let key = base_id(&fill.exec_id).to_string();
        if let Some(existing) = self.fills.get(&key) {
            // Keep the latest correction; ignore repeats of what we have.
            if existing.exec_id.as_str() >= fill.exec_id.as_str() {
                return false;
            }
        }
        if let Some(c) = self.charges.get(&fill.exec_id) {
            fill.commission = Some(c.commission);
            fill.realized_pnl = c.realized_pnl;
        }
        self.fills.insert(key, fill);
        true
    }

    pub fn add_charge(&mut self, exec_id: &str, charge: Charge) -> bool {
        if self.charges.get(exec_id) == Some(&charge) {
            return false;
        }
        self.charges.insert(exec_id.to_string(), charge);
        match self.fills.get_mut(base_id(exec_id)) {
            Some(f) if f.exec_id == exec_id => {
                f.commission = Some(charge.commission);
                f.realized_pnl = charge.realized_pnl;
            }
            _ => {}
        }
        true
    }

    /// How many days of executions to ask IB for: back to the day after the last read
    /// (and that day itself, in case it ended mid-day), at least today and yesterday, at most IB's window.
    pub fn days_to_read(&self, today: Date) -> i32 {
        let last = self.covered_through.as_deref().and_then(|d| Date::strptime("%Y%m%d", d).ok());
        match last {
            Some(last) if last <= today => {
                let gap = (today - last).get_days() as i64 + 1;
                gap.clamp(2, BACKFILL_DAYS as i64) as i32
            }
            _ => BACKFILL_DAYS,
        }
    }

    /// Records that IB's executions were read for `from`..=`today`. History stays complete
    /// back to `since` only if this read joins the last one; after a longer gap (the app
    /// off for more than IB's window) it restarts at `from`.
    pub fn note_coverage(&mut self, from: Date, today: Date) -> bool {
        let joins = self
            .covered_through
            .as_deref()
            .is_some_and(|last| last >= ymd(from - 1.day()).as_str());
        let since = match (&self.since, joins) {
            (Some(since), true) => since.clone().min(ymd(from)),
            _ => ymd(from),
        };
        let through = ymd(today);
        let changed = self.since.as_deref() != Some(since.as_str()) || self.covered_through.as_deref() != Some(through.as_str());
        self.since = Some(since);
        self.covered_through = Some(through);
        changed
    }

    pub fn snapshot(&self, account: &str, today: Date) -> LedgerSnapshot {
        let tallies = [PnlPeriod::Day, PnlPeriod::Week, PnlPeriod::Month, PnlPeriod::Year]
            .into_iter()
            .map(|p| self.tally(p, period_start(p, today)))
            .collect();
        LedgerSnapshot { account: account.to_string(), tallies, recorded_since: self.since.clone() }
    }

    fn tally(&self, period: PnlPeriod, from: Date) -> PnlTally {
        let from_day = ymd(from);
        let mut t = PnlTally {
            period,
            from_day: from_day.clone(),
            net_realized: 0.0,
            commissions: 0.0,
            fills: 0,
            closing_fills: 0,
            winners: 0,
            losers: 0,
            awaiting_commission: 0,
            complete: self.since.as_deref().is_some_and(|s| s <= from_day.as_str()),
        };
        for f in self.fills.values().filter(|f| f.day >= from_day) {
            t.fills += 1;
            match f.commission {
                Some(c) => t.commissions += c,
                None => t.awaiting_commission += 1,
            }
            if let Some(pnl) = f.realized_pnl {
                t.closing_fills += 1;
                t.net_realized += pnl;
                if pnl > 0.0 {
                    t.winners += 1;
                } else if pnl < 0.0 {
                    t.losers += 1;
                }
            }
        }
        t
    }
}

fn ymd(d: Date) -> String {
    d.strftime("%Y%m%d").to_string()
}

/// Day: today. Week: since Monday. Month: since the 1st. Year: since Jan 1.
pub(crate) fn period_start(period: PnlPeriod, today: Date) -> Date {
    match period {
        PnlPeriod::Day => today,
        PnlPeriod::Week => today - (today.weekday().to_monday_zero_offset() as i64).days(),
        PnlPeriod::Month => today.first_of_month(),
        PnlPeriod::Year => today.first_of_year(),
    }
}

/// IB's execution time ("20261116 10:23:45 US/Eastern", or "20261116-15:23:45" in UTC)
/// as a US/Eastern day. Falls back to the date as written.
pub(crate) fn eastern_day(time: &str) -> Option<String> {
    let time = time.trim();
    let date = time.get(..8).filter(|d| d.bytes().all(|b| b.is_ascii_digit()))?;
    let rest = time[8..].trim_start();
    let (utc, rest) = match rest.strip_prefix('-') {
        Some(r) => (true, r),
        None => (false, rest),
    };
    let mut parts = rest.split_whitespace();
    let converted = parts.next().and_then(|clock| {
        let civil = DateTime::strptime("%Y%m%d %H:%M:%S", format!("{date} {clock}")).ok()?;
        let tz = if utc {
            TimeZone::UTC
        } else {
            match parts.next() {
                Some(name) => TimeZone::get(name).ok()?,
                None => strategy::eastern(),
            }
        };
        let zoned = civil.to_zoned(tz).ok()?.with_time_zone(strategy::eastern());
        Some(ymd(zoned.date()))
    });
    Some(converted.unwrap_or_else(|| date.to_string()))
}

fn today() -> Date {
    Zoned::now().with_time_zone(strategy::eastern()).date()
}

fn fill_from(d: &ExecutionData) -> Option<Fill> {
    let e = &d.execution;
    Some(Fill {
        exec_id: e.execution_id.clone(),
        day: eastern_day(&e.time)?,
        local_symbol: if d.contract.local_symbol.is_empty() { d.contract.symbol.to_string() } else { d.contract.local_symbol.clone() },
        sec_type: d.contract.security_type.to_string(),
        bought: matches!(e.side, ExecutionSide::Bought),
        shares: e.shares,
        price: e.price,
        commission: None,
        realized_pnl: None,
    })
}

fn charge_from(c: &CommissionReport) -> Charge {
    Charge { commission: value(Some(c.commission)).unwrap_or(0.0), realized_pnl: value(c.realized_pnl) }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

/// A missing file is an empty ledger; an unreadable one is an error (never overwritten).
fn load(path: &Path) -> Result<Ledger, String> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("Can't read the P&L ledger ({}): {e}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Ledger::default()),
        Err(e) => Err(format!("Can't read the P&L ledger ({}): {e}", path.display())),
    }
}

/// Write-then-rename, so a crash never leaves a half-written file.
fn save(path: &Path, ledger: &Ledger) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec(ledger)?)?;
    std::fs::rename(tmp, path)
}

// ---------------------------------------------------------------------------
// Stream
// ---------------------------------------------------------------------------

/// Reads one executions request to its end into the ledger. Returns whether anything changed.
async fn read_executions(client: &Client, account: &str, last_n_days: i32, ledger: &mut Ledger) -> Result<bool, String> {
    let filter = ExecutionFilter { account_code: account.to_string(), last_n_days, ..Default::default() };
    let sub = client.executions(filter).await.map_err(|e| e.to_string())?;
    let mut sub = sub.filter_data();
    let mut changed = false;
    let read = async {
        while let Some(item) = sub.next().await {
            match item {
                Ok(Executions::ExecutionData(d)) if d.execution.account_number == account || account.is_empty() => {
                    if let Some(fill) = fill_from(&d) {
                        changed |= ledger.add_fill(fill);
                    }
                }
                Ok(Executions::CommissionReport(c)) => changed |= ledger.add_charge(&c.execution_id, charge_from(&c)),
                Ok(_) => {}
                Err(e) => return Err(e.to_string()),
            }
        }
        Ok(())
    };
    match tokio::time::timeout(Duration::from_secs(10), read).await {
        Ok(Err(e)) => Err(e),
        _ => Ok(changed),
    }
}

pub(crate) async fn run_ledger(client: &Client, account: String, path: PathBuf, listener: &dyn LedgerListener) {
    let mut ledger = match load(&path) {
        Ok(l) => l,
        Err(e) => {
            // Don't overwrite a ledger we couldn't read.
            listener.on_error(e);
            return;
        }
    };
    let persist = |ledger: &Ledger| {
        if let Err(e) = save(&path, ledger) {
            listener.on_error(format!("Can't save the P&L ledger: {e}"));
        }
    };
    listener.on_ledger(ledger.snapshot(&account, today()));

    let mut last_day = today();
    loop {
        if client.is_connected() {
            let now = today();
            let days = ledger.days_to_read(now);
            match read_executions(client, &account, days, &mut ledger).await {
                Ok(changed) => {
                    let from = now - ((days - 1) as i64).days();
                    let changed = changed | ledger.note_coverage(from, now);
                    if changed {
                        persist(&ledger);
                    }
                    if changed || today() != last_day {
                        last_day = today();
                        listener.on_ledger(ledger.snapshot(&account, last_day));
                    }
                }
                Err(e) => listener.on_error(format!("P&L ledger: {e}")),
            }
        }
        tokio::time::sleep(POLL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    fn fill(id: &str, day: &str) -> Fill {
        Fill {
            exec_id: id.into(),
            day: day.into(),
            local_symbol: "SPY".into(),
            sec_type: "OPT".into(),
            bought: false,
            shares: 1.0,
            price: 1.0,
            commission: None,
            realized_pnl: None,
        }
    }

    #[test]
    fn period_starts() {
        let wed = date(2026, 11, 18);
        assert_eq!(period_start(PnlPeriod::Day, wed), wed);
        assert_eq!(period_start(PnlPeriod::Week, wed), date(2026, 11, 16));
        assert_eq!(period_start(PnlPeriod::Week, date(2026, 11, 16)), date(2026, 11, 16));
        assert_eq!(period_start(PnlPeriod::Week, date(2026, 11, 22)), date(2026, 11, 16)); // Sunday
        assert_eq!(period_start(PnlPeriod::Month, wed), date(2026, 11, 1));
        assert_eq!(period_start(PnlPeriod::Year, wed), date(2026, 1, 1));
    }

    #[test]
    fn eastern_days() {
        assert_eq!(eastern_day("20261116 10:23:45 US/Eastern").as_deref(), Some("20261116"));
        // 02:00 UTC is still the previous day in New York.
        assert_eq!(eastern_day("20261117-02:00:00").as_deref(), Some("20261116"));
        assert_eq!(eastern_day("20261116  23:30:00 Europe/London").as_deref(), Some("20261116"));
        assert_eq!(eastern_day("20261117 01:30:00 Europe/London").as_deref(), Some("20261116"));
        assert_eq!(eastern_day("20261116 10:23:45 Nowhere/Zone").as_deref(), Some("20261116"));
        assert_eq!(eastern_day("garbage"), None);
    }

    #[test]
    fn commission_joins_either_order() {
        let mut l = Ledger::default();
        assert!(l.add_fill(fill("a.01", "20261116")));
        assert!(l.add_charge("a.01", Charge { commission: 0.65, realized_pnl: Some(10.0) }));
        // Charge before fill.
        assert!(l.add_charge("b.01", Charge { commission: 1.3, realized_pnl: None }));
        assert!(l.add_fill(fill("b.01", "20261116")));
        let t = &l.snapshot("DU1", date(2026, 11, 16)).tallies[0];
        assert_eq!(t.fills, 2);
        assert_eq!(t.closing_fills, 1);
        assert!((t.commissions - 1.95).abs() < 1e-9);
        assert!((t.net_realized - 10.0).abs() < 1e-9);
        assert_eq!(t.awaiting_commission, 0);
    }

    #[test]
    fn repeats_are_ignored_and_corrections_replace() {
        let mut l = Ledger::default();
        assert!(l.add_fill(fill("x.01", "20261116")));
        assert!(!l.add_fill(fill("x.01", "20261116")));
        assert!(l.add_charge("x.01", Charge { commission: 1.0, realized_pnl: Some(5.0) }));
        assert!(!l.add_charge("x.01", Charge { commission: 1.0, realized_pnl: Some(5.0) }));
        // Correction: new exec id, new commission report.
        assert!(l.add_fill(fill("x.02", "20261116")));
        let t = &l.snapshot("DU1", date(2026, 11, 16)).tallies[0];
        assert_eq!(t.fills, 1);
        assert_eq!(t.awaiting_commission, 1);
        assert!(l.add_charge("x.02", Charge { commission: 1.0, realized_pnl: Some(-2.0) }));
        let t = &l.snapshot("DU1", date(2026, 11, 16)).tallies[0];
        assert!((t.net_realized + 2.0).abs() < 1e-9);
        assert_eq!(t.losers, 1);
        // An older correction arriving late doesn't win.
        assert!(!l.add_fill(fill("x.01", "20261116")));
    }

    #[test]
    fn tallies_by_period_and_completeness() {
        let mut l = Ledger::default();
        for (id, day, pnl) in [("d.01", "20261118", 10.0), ("w.01", "20261116", -4.0), ("m.01", "20261103", 20.0), ("y.01", "20260302", 100.0)] {
            l.add_fill(fill(id, day));
            l.add_charge(id, Charge { commission: 1.0, realized_pnl: Some(pnl) });
        }
        l.note_coverage(date(2026, 11, 12), date(2026, 11, 18));
        let s = l.snapshot("DU1", date(2026, 11, 18));
        let net: Vec<f64> = s.tallies.iter().map(|t| t.net_realized).collect();
        assert_eq!(net, vec![10.0, 6.0, 26.0, 126.0]);
        assert_eq!(s.recorded_since.as_deref(), Some("20261112"));
        let complete: Vec<bool> = s.tallies.iter().map(|t| t.complete).collect();
        assert_eq!(complete, vec![true, true, false, false]);
    }

    #[test]
    fn coverage_joins_or_restarts_after_a_gap() {
        let mut l = Ledger::default();
        assert_eq!(l.days_to_read(date(2026, 11, 18)), BACKFILL_DAYS);
        l.note_coverage(date(2026, 11, 12), date(2026, 11, 18));
        // Next day: reads two days, and history stays complete from the 12th.
        assert_eq!(l.days_to_read(date(2026, 11, 19)), 2);
        l.note_coverage(date(2026, 11, 18), date(2026, 11, 19));
        assert_eq!(l.since.as_deref(), Some("20261112"));
        // Four days off: reads back to the last day covered.
        assert_eq!(l.days_to_read(date(2026, 11, 23)), 5);
        l.note_coverage(date(2026, 11, 19), date(2026, 11, 23));
        assert_eq!(l.since.as_deref(), Some("20261112"));
        // Off for weeks: IB's window can't reach back, so completeness restarts.
        assert_eq!(l.days_to_read(date(2026, 12, 20)), BACKFILL_DAYS);
        l.note_coverage(date(2026, 12, 14), date(2026, 12, 20));
        assert_eq!(l.since.as_deref(), Some("20261214"));
    }

    #[test]
    fn no_value_is_filtered() {
        assert_eq!(value(Some(f64::MAX)), None);
        assert_eq!(value(Some(f64::NAN)), None);
        assert_eq!(value(Some(-3.5)), Some(-3.5));
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = std::env::temp_dir().join(format!("ledger-test-{}", std::process::id()));
        let path = dir.join("DU1.json");
        let mut l = Ledger::default();
        l.add_fill(fill("r.01", "20261116"));
        l.add_charge("r.01", Charge { commission: 0.5, realized_pnl: Some(1.0) });
        l.note_coverage(date(2026, 11, 10), date(2026, 11, 16));
        save(&path, &l).unwrap();
        let back = load(&path).unwrap();
        assert_eq!(back.fills, l.fills);
        assert_eq!(back.since, l.since);
        std::fs::write(&path, b"not json").unwrap();
        assert!(load(&path).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
