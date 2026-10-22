//! Thin FFI layer over `ibapi` for the IBKR Swift app. See CLAUDE.md for the architecture.

mod session;
mod types;

pub use session::*;
pub use types::*;

uniffi::setup_scaffolding!();
