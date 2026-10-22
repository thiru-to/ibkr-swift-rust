//! Plain data types that cross the FFI boundary.

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum IbkrError {
    #[error("{message}")]
    Api { message: String },
    #[error("{message}")]
    Invalid { message: String },
}

impl From<ibapi::Error> for IbkrError {
    fn from(e: ibapi::Error) -> Self {
        IbkrError::Api { message: e.to_string() }
    }
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct AccountSummary {
    pub account: String,
    pub currency: String,
    pub net_liquidation: Option<f64>,
    pub total_cash: Option<f64>,
    pub buying_power: Option<f64>,
    pub available_funds: Option<f64>,
    pub gross_position_value: Option<f64>,
    pub daily_pnl: Option<f64>,
    pub unrealized_pnl: Option<f64>,
    pub realized_pnl: Option<f64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Position {
    pub account: String,
    pub contract_id: i32,
    pub symbol: String,
    /// e.g. "STK", "OPT".
    pub sec_type: String,
    /// IB's full contract name, e.g. "OPEN  261218C00010000" for an option.
    pub local_symbol: String,
    pub currency: String,
    pub quantity: f64,
    pub average_cost: f64,
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct Quote {
    pub symbol: String,
    pub bid: Option<f64>,
    pub ask: Option<f64>,
    pub last: Option<f64>,
    pub close: Option<f64>,
    pub bid_size: Option<f64>,
    pub ask_size: Option<f64>,
    pub volume: Option<f64>,
    /// True when IB is serving delayed (non-subscribed) data.
    pub delayed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OrderSide {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum OrderKind {
    Market,
    Limit { price: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TimeInForce {
    Day,
    Gtc,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct OrderRequest {
    pub symbol: String,
    pub side: OrderSide,
    pub quantity: f64,
    pub kind: OrderKind,
    pub tif: TimeInForce,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct OpenOrder {
    pub order_id: i32,
    pub symbol: String,
    pub action: String,
    pub order_type: String,
    pub quantity: f64,
    pub filled: f64,
    pub limit_price: Option<f64>,
    pub status: String,
}
