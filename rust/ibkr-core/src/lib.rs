//! Thin FFI layer over `ibapi` for the IBKR Swift app. See CLAUDE.md for the architecture.

mod options;
mod orders;
mod position;
mod risk;
mod session;
mod strategy;
mod types;

pub use risk::RiskListener;
pub use session::*;
pub use strategy::{StrategyHandle, StrategyListener};
pub use types::*;

uniffi::setup_scaffolding!();
