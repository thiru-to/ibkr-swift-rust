//! Thin FFI layer over `ibapi` for the IBKR Swift app. See CLAUDE.md for the architecture.

mod options;
mod session;
mod strategy;
mod types;

pub use session::*;
pub use strategy::{StrategyHandle, StrategyListener};
pub use types::*;

uniffi::setup_scaffolding!();
