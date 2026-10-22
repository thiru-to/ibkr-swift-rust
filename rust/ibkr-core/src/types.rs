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

/// Coarse grouping of IB's order statuses, for filtering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum OrderStatusGroup {
    /// ApiPending, PendingSubmit, PreSubmitted, Submitted, PendingCancel.
    Open,
    Filled,
    /// Cancelled, ApiCancelled (IB also uses Cancelled for some rejections).
    Cancelled,
    /// Received but no longer active: rejected or cancelled by IB.
    Inactive,
    /// A status this version of ibapi doesn't model.
    Other,
}

/// Any order IB reported this session: working orders plus today's completed ones.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OrderInfo {
    pub order_id: i32,
    /// IB's permanent id (unique across clients); 0 until IB assigns it.
    pub perm_id: i64,
    pub account: String,
    pub symbol: String,
    /// IB's full contract name, e.g. "SPY   261022C00763000".
    pub local_symbol: String,
    pub sec_type: String,
    pub action: String,
    pub order_type: String,
    pub tif: String,
    pub quantity: f64,
    pub filled: f64,
    pub limit_price: Option<f64>,
    pub stop_price: Option<f64>,
    pub average_fill_price: Option<f64>,
    /// IB's raw status, e.g. "PreSubmitted", "Filled", "ApiCancelled".
    pub status: String,
    pub group: OrderStatusGroup,
    /// Completion text ("Cancelled by Trader", "Filled Size: 1"), rejection reason, or why held.
    pub detail: String,
    /// When IB completed it (completed orders only), as sent by IB.
    pub completed_time: String,
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum OptionRight {
    Call,
    Put,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct OptionSpec {
    pub symbol: String,
    /// "YYYYMMDD"
    pub expiry: String,
    pub right: OptionRight,
    pub strike: f64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct OptionChain {
    pub symbol: String,
    pub underlying_conid: i32,
    /// Sorted "YYYYMMDD"; the first entry is the nearest expiry.
    pub expirations: Vec<String>,
    /// Union across expirations; not every strike exists for every expiry.
    pub strikes: Vec<f64>,
    pub multiplier: f64,
}

// ---------------------------------------------------------------------------
// Strategies: trigger on the underlying → market buy → OCA exits
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TriggerDirection {
    /// Fires when the underlying's last trade is at or above the price.
    RisesTo,
    /// Fires when the underlying's last trade is at or below the price.
    FallsTo,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Trigger {
    pub underlying: String,
    pub direction: TriggerDirection,
    pub price: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum Target {
    /// Percent of the entry premium.
    Percent { value: f64 },
    /// Total dollars for the whole position.
    Dollars { value: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum StopKind {
    StopMarket,
    /// Limit = stop − offset.
    StopLimit { limit_offset: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct StopSpec {
    pub target: Target,
    pub kind: StopKind,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StrategySpec {
    pub option: OptionSpec,
    pub quantity: f64,
    /// None = enter immediately.
    pub trigger: Option<Trigger>,
    pub take_profit: Option<Target>,
    pub stop_loss: Option<StopSpec>,
    /// "HH:MM" US/Eastern, today.
    pub eod_close: Option<String>,
    /// Let the trigger fire on delayed data. Paper testing only; the app forces it off on live.
    pub allow_delayed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StrategyState {
    Arming,
    Armed,
    /// Trigger is paused because the underlying's data is delayed.
    WaitingDelayedData,
    Entering,
    /// Filled, with exit orders held by IB.
    Protected,
    /// Filled, no exits were requested.
    Open,
    Closing,
    Closed,
    Disarmed,
    Failed,
    /// Filled but an exit order was rejected: the position needs attention.
    Unprotected,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StrategyUpdate {
    pub id: u64,
    pub state: StrategyState,
    pub message: String,
    pub option_local_symbol: String,
    pub underlying_last: Option<f64>,
    pub underlying_delayed: bool,
    pub entry_order_id: Option<i32>,
    pub filled_quantity: f64,
    pub average_fill: Option<f64>,
    pub take_profit_price: Option<f64>,
    pub stop_price: Option<f64>,
    pub stop_limit_price: Option<f64>,
    /// "YYYYMMDD HH:MM:SS US/Eastern"
    pub eod_close_at: Option<String>,
    pub exit_price: Option<f64>,
    pub realized_pnl: Option<f64>,
    /// The app must stay open and connected for this strategy to work (trigger not yet
    /// fired, entry in flight, or the EOD close is app-managed).
    pub requires_app: bool,
}
