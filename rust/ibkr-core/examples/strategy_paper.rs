//! PAPER-ONLY end-to-end strategy test: 1 SPY 0DTE ATM call, TP +50%, SL -30%, EOD 15:50.
//! Waits for the entry to be protected, prints open orders, then closes with close_now.
//!
//! cargo run --example strategy_paper -- immediate
//! cargo run --example strategy_paper -- trigger     (fires on the next uptick, delayed data allowed)
//! cargo run --example strategy_paper -- halt        (arms a trigger that can't fire, halts trading,
//!                                                    and checks that nothing can be entered; places
//!                                                    no orders unless the risk guard is broken)
//!
//! Refuses to run against a live port or a non-paper ("D…") account.

use std::sync::{Arc, mpsc};
use std::time::Duration;

use ibkr_core::*;

struct Updates(mpsc::Sender<StrategyUpdate>);
impl StrategyListener for Updates {
    fn on_update(&self, u: StrategyUpdate) {
        let _ = self.0.send(u);
    }
}

struct Last(mpsc::Sender<f64>);
impl QuoteListener for Last {
    fn on_quote(&self, q: Quote) {
        if let Some(p) = q.last.or(q.bid) {
            let _ = self.0.send(p);
        }
    }
    fn on_error(&self, m: String) {
        eprintln!("quote error: {m}");
    }
}

struct Orders(mpsc::Sender<Vec<OrderInfo>>);
impl OrdersListener for Orders {
    fn on_orders(&self, o: Vec<OrderInfo>) {
        let _ = self.0.send(o);
    }
    fn on_error(&self, m: String) {
        eprintln!("orders error: {m}");
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mode = std::env::args().nth(1).unwrap_or_default();
    let triggered = mode == "trigger";
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build()?;

    let session = rt.block_on(connect("127.0.0.1".into(), 4002, 904))?;
    let account = session.account();
    if session.is_live() || !account.starts_with('D') {
        return Err(format!("refusing to run: {account} is not a paper account").into());
    }
    println!("paper account {account}");

    let chain = rt.block_on(session.option_chain("SPY".into()))?;
    let expiry = chain.expirations[0].clone();
    println!("SPY chain: {} expirations (first {expiry}), {} strikes", chain.expirations.len(), chain.strikes.len());

    let (tx, rx) = mpsc::channel();
    let quote = session.subscribe_quote("SPY".into(), Arc::new(Last(tx)));
    let spy = rx.recv_timeout(Duration::from_secs(10))?;
    drop(quote);
    let strike = *chain.strikes.iter().min_by(|a, b| (*a - spy).abs().total_cmp(&(*b - spy).abs())).unwrap();
    println!("SPY {spy} → ATM strike {strike}");

    if mode == "halt" {
        let option = OptionSpec { symbol: "SPY".into(), expiry, right: OptionRight::Call, strike };
        return halt_test(&rt, &session, option, spy);
    }

    let (otx, orx) = mpsc::channel();
    let _orders = session.subscribe_orders(Arc::new(Orders(otx)));

    let spec = StrategySpec {
        option: OptionSpec { symbol: "SPY".into(), expiry, right: OptionRight::Call, strike },
        quantity: 1.0,
        trigger: triggered.then(|| Trigger {
            underlying: "SPY".into(),
            direction: TriggerDirection::RisesTo,
            price: ((spy + 0.02) * 100.0).round() / 100.0,
        }),
        take_profit: Some(Target::Percent { value: 50.0 }),
        stop_loss: Some(StopSpec { target: Target::Percent { value: 30.0 }, kind: StopKind::StopMarket }),
        eod_close: Some("15:50".into()),
        allow_delayed: true,
    };
    println!("arming: {spec:?}");
    let (utx, urx) = mpsc::channel();
    let handle = session.arm_strategy(spec, Arc::new(Updates(utx)));

    let mut closed_requested = false;
    let mut last_state = None;
    loop {
        let u = match urx.recv_timeout(Duration::from_secs(180)) {
            Ok(u) => u,
            Err(_) => {
                println!("timed out waiting for updates; disarming");
                handle.disarm();
                break;
            }
        };
        if last_state != Some(u.state) || !matches!(u.state, StrategyState::Armed | StrategyState::WaitingDelayedData) {
            println!(
                "[{:?}] {} | {} | last={:?} fill={:?} tp={:?} stop={:?} eod={:?} exit={:?} pnl={:?}",
                u.state, u.message, u.option_local_symbol, u.underlying_last, u.average_fill,
                u.take_profit_price, u.stop_price, u.eod_close_at, u.exit_price, u.realized_pnl
            );
        }
        last_state = Some(u.state);
        match u.state {
            StrategyState::Protected | StrategyState::Unprotected | StrategyState::Open if !closed_requested => {
                std::thread::sleep(Duration::from_secs(4));
                let mut latest = Vec::new();
                while let Ok(o) = orx.try_recv() {
                    latest = o;
                }
                println!("open orders now:");
                latest.iter().for_each(|o| println!("  {o:?}"));
                println!("→ close_now");
                closed_requested = true;
                handle.close_now();
            }
            StrategyState::Closed | StrategyState::Failed | StrategyState::Disarmed => break,
            _ => {}
        }
    }

    std::thread::sleep(Duration::from_secs(3));
    let mut latest = None;
    while let Ok(o) = orx.try_recv() {
        latest = Some(o);
    }
    println!("open orders after close: {:?}", latest.map(|o| o.into_iter().map(|o| (o.order_id, o.symbol, o.order_type, o.status)).collect::<Vec<_>>()));
    rt.block_on(session.disconnect())?;
    Ok(())
}

/// Waits for a strategy to reach a terminal state (or Armed, if `until_armed`).
fn wait(urx: &mpsc::Receiver<StrategyUpdate>, until_armed: bool) -> Result<StrategyUpdate, Box<dyn std::error::Error>> {
    loop {
        let u = urx.recv_timeout(Duration::from_secs(60))?;
        println!("  [{:?}] {}", u.state, u.message);
        match u.state {
            StrategyState::Armed if until_armed => return Ok(u),
            StrategyState::Closed | StrategyState::Failed | StrategyState::Disarmed => return Ok(u),
            StrategyState::Entering | StrategyState::Protected | StrategyState::Open => {
                return Err(format!("strategy reached {:?}: the risk guard let an entry through", u.state).into());
            }
            _ => {}
        }
    }
}

/// The kill switch: a halt must disarm an armed strategy, refuse new ones and refuse buys.
/// The trigger is 50% above SPY, so it can't fire during the test.
fn halt_test(
    rt: &tokio::runtime::Runtime,
    session: &IbkrSession,
    option: OptionSpec,
    spy: f64,
) -> Result<(), Box<dyn std::error::Error>> {
    let spec = StrategySpec {
        option,
        quantity: 1.0,
        trigger: Some(Trigger { underlying: "SPY".into(), direction: TriggerDirection::RisesTo, price: (spy * 1.5).round() }),
        take_profit: None,
        stop_loss: None,
        eod_close: None,
        allow_delayed: true,
    };

    println!("1. arm a strategy that can't trigger");
    let (utx, urx) = mpsc::channel();
    let _handle = session.arm_strategy(spec.clone(), Arc::new(Updates(utx)));
    let u = wait(&urx, true)?;
    if u.state != StrategyState::Armed {
        return Err(format!("expected Armed, got {:?}", u.state).into());
    }

    println!("2. halt trading");
    session.halt_trading("paper halt test".into());
    let u = wait(&urx, false)?;
    if u.state != StrategyState::Disarmed || !u.message.contains("halted") {
        return Err(format!("expected Disarmed by the halt, got {:?}: {}", u.state, u.message).into());
    }
    println!("   status: {:?}", session.risk_status());

    println!("3. arming while halted must fail");
    let (utx, urx) = mpsc::channel();
    let _handle = session.arm_strategy(spec, Arc::new(Updates(utx)));
    let u = wait(&urx, false)?;
    if u.state != StrategyState::Failed || !u.message.contains("halted") {
        return Err(format!("expected Failed (halted), got {:?}: {}", u.state, u.message).into());
    }

    println!("4. a buy while halted must be refused before it's sent");
    let buy = OrderRequest {
        symbol: "SPY".into(),
        side: OrderSide::Buy,
        quantity: 1.0,
        kind: OrderKind::Limit { price: 1.0 },
        tif: TimeInForce::Day,
    };
    match rt.block_on(session.place_order(buy)) {
        Err(e) if e.to_string().contains("halted") => println!("   refused: {e}"),
        Err(e) => return Err(format!("refused for the wrong reason: {e}").into()),
        Ok(placed) => {
            // A $1 limit on SPY can't fill; take it back straight away.
            let _ = rt.block_on(session.cancel_order(placed.order_id));
            return Err(format!("the buy was SENT (order #{}, cancelled): the risk guard is broken", placed.order_id).into());
        }
    }

    println!("halt test passed: nothing was entered");
    rt.block_on(session.disconnect())?;
    Ok(())
}
