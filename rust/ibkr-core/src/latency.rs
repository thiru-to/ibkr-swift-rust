//! Fill latency of strategy entries (option market buys), timed in the app.
//!
//! IB's order statuses carry no timestamps, and execution times are server-side whole
//! seconds, so every phase is timed on a monotonic clock as each event reaches this
//! process: submit → handed to Gateway → first status (IB's ack) → first fill → filled.
//! That's the delay the app actually sees, including Gateway and the network. Records are
//! appended one JSON object per line to a per-account log (path set by Swift).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::time::Instant;

use crate::types::OrderTiming;

/// Where finished entries are logged; None until Swift sets it.
pub(crate) type LatencyLog = Arc<Mutex<Option<PathBuf>>>;

fn ms(d: std::time::Duration) -> f64 {
    // Microsecond resolution, reported in milliseconds.
    (d.as_micros() as f64) / 1000.0
}

fn now_unix_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Times one order from the moment it's submitted.
pub(crate) struct Stopwatch {
    start: Instant,
    pub timing: OrderTiming,
}

impl Stopwatch {
    /// Call right before `place_order`. `triggered_at` is when the trigger tick arrived.
    pub fn start(order_id: i32, local_symbol: &str, quantity: f64, triggered_at: Option<Instant>, ask: Option<f64>) -> Self {
        let start = Instant::now();
        Stopwatch {
            start,
            timing: OrderTiming {
                order_id,
                local_symbol: local_symbol.to_string(),
                quantity,
                submitted_at_ms: now_unix_ms(),
                trigger_to_submit_ms: triggered_at.map(|t| ms(start.saturating_duration_since(t))),
                sent_ms: None,
                ack_ms: None,
                ack_status: String::new(),
                first_fill_ms: None,
                filled_ms: None,
                average_fill: None,
                ask_at_submit: ask,
                outcome: "Working".into(),
            },
        }
    }

    fn elapsed(&self) -> f64 {
        ms(self.start.elapsed())
    }

    /// `place_order` returned: the order was written to Gateway's socket.
    pub fn sent(&mut self) {
        self.timing.sent_ms = Some(self.elapsed());
    }

    /// Any status from IB. The first is the ack; the first with a fill and the Filled one
    /// are recorded once.
    pub fn status(&mut self, status: &str, filled: f64, average: Option<f64>, done: bool) {
        let now = self.elapsed();
        if self.timing.ack_ms.is_none() {
            self.timing.ack_ms = Some(now);
            self.timing.ack_status = status.to_string();
        }
        if filled > 0.0 && self.timing.first_fill_ms.is_none() {
            self.timing.first_fill_ms = Some(now);
        }
        if done && self.timing.filled_ms.is_none() {
            self.timing.filled_ms = Some(now);
        }
        if average.is_some() {
            self.timing.average_fill = average;
        }
    }
}

/// Appends one record. Best-effort: timing must never get in the way of trading.
pub(crate) fn append(log: &LatencyLog, timing: &OrderTiming) {
    let path = log.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(path) = path {
        let _ = append_to(&path, timing);
    }
}

fn append_to(path: &Path, timing: &OrderTiming) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut line = serde_json::to_vec(timing)?;
    line.push(b'\n');
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(&line)
}

/// Every logged record, oldest first; unreadable lines are skipped.
pub(crate) fn read(path: &Path) -> Vec<OrderTiming> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test(start_paused = true)]
    async fn phases_are_recorded_once() {
        let triggered = Instant::now();
        tokio::time::advance(Duration::from_micros(2_500)).await;
        let mut w = Stopwatch::start(7, "SPY 261116C00600000", 10.0, Some(triggered), Some(1.25));
        assert_eq!(w.timing.trigger_to_submit_ms, Some(2.5));

        tokio::time::advance(Duration::from_micros(300)).await;
        w.sent();
        tokio::time::advance(Duration::from_millis(40)).await;
        w.status("PreSubmitted", 0.0, None, false);
        tokio::time::advance(Duration::from_millis(10)).await;
        w.status("Submitted", 0.0, None, false);
        tokio::time::advance(Duration::from_millis(150)).await;
        w.status("Submitted", 4.0, Some(1.26), false);
        tokio::time::advance(Duration::from_millis(50)).await;
        w.status("Filled", 10.0, Some(1.27), true);
        w.status("Filled", 10.0, Some(1.27), true); // IB repeats Filled

        let t = &w.timing;
        assert_eq!(t.sent_ms, Some(0.3));
        assert_eq!(t.ack_ms, Some(40.3));
        assert_eq!(t.ack_status, "PreSubmitted");
        assert_eq!(t.first_fill_ms, Some(200.3));
        assert_eq!(t.filled_ms, Some(250.3));
        assert_eq!(t.average_fill, Some(1.27));
    }

    #[test]
    fn log_round_trip_skips_bad_lines() {
        let dir = std::env::temp_dir().join(format!("latency-test-{}", std::process::id()));
        let path = dir.join("DU1.jsonl");
        let log: LatencyLog = Arc::new(Mutex::new(Some(path.clone())));
        let w = Stopwatch::start(1, "X", 1.0, None, None);
        append(&log, &w.timing);
        std::fs::OpenOptions::new().append(true).open(&path).unwrap().write_all(b"garbage\n").unwrap();
        append(&log, &w.timing);
        let back = read(&path);
        assert_eq!(back.len(), 2);
        assert_eq!(back[0], w.timing);
        let _ = std::fs::remove_dir_all(dir);
    }
}
