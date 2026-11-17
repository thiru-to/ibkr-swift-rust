//! Thin FFI layer over `ibapi` for the IBKR Swift app. See CLAUDE.md for the architecture.

mod chart_levels;
mod latency;
mod ledger;
mod options;
mod orders;
mod position;
mod risk;
mod session;
mod search;
mod strategy;
mod types;

pub use ledger::LedgerListener;
pub use risk::RiskListener;
pub use session::*;
pub use strategy::{StrategyHandle, StrategyListener};
pub use types::*;

uniffi::setup_scaffolding!();
