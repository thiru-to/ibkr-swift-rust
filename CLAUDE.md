# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Minimal native macOS client for a locally running IB Gateway. The Rust core wraps the `ibapi` crate (async/Tokio), and a SwiftUI app sits on top, bridged with UniFFI.

## Safety

- **Port 4001 is the LIVE Gateway port (real money)**; 4002 is paper. The **Account → Trading Mode** menu (only while disconnected) selects Live or Paper, which sets the port; the choice persists in UserDefaults and defaults to Paper. Host, port and client id persist too, so a port typed by hand survives a relaunch; `isLive` still catches it.
- `AppStore.isLive` is deliberately conservative: it's true if the mode is Live, *or* the port is a live port (`IbkrSession::is_live()`: 4001 or 7496), *or* the account id doesn't start with `D` (IB paper ids look like `DU…`). A Paper/live mismatch shows a warning.
- Every order submit in `OrdersView.swift` goes through a confirmation sheet (`OrderConfirmSheet`) that shows the account, LIVE/PAPER and price sanity warnings (`OrderCheck`). Keep that step, and keep the submit button free of a Return shortcut.
- The Quote screen's trade panel (`QuoteTradePanel.swift`) reviews every submit too, on paper and LIVE, and its market close always sends the reviewed quantity (`expected_quantity`).
- Position actions (`PositionDetailView.swift`: close, add stop/take-profit, edit a working order's price) also go through a review panel showing LIVE/PAPER, with no Return shortcut. Keep that.
- Arming a strategy (`OptionsView.swift`) goes through a confirmation dialog showing LIVE/PAPER. The P/L simulator next to the ticket is display-only and must stay that way.
- The exception is **Quick Buy** on the Options screen, an immediate market buy of preset ATM contracts (default 10 SPY) on the nearest expiry with the ticket's exits. It still goes through `arm_strategy`, so the risk checks and OCA exits apply. It's one click on paper. On LIVE it opens `QuickBuyConfirmSheet`, where Cancel is the default and the buy button has no shortcut. A ~2s lockout blocks re-presses. Its keyboard shortcuts (`QuickBuyShortcuts.swift`, set in Settings) are off by default and work only while the Options screen shows. They must include ⌘ or ⌃ and can never be Return, Enter, Space, Tab or Esc. Keep those rules.
- **Close Now** on a strategy row (`StrategiesView.swift`) sells at market right away, with no confirmation, on paper and LIVE alike. The user asked for this. It's an exit inside the strategy's OCA group, and the task ignores repeat presses once it's closing. The Close via Strategy button in `PositionDetailView` still asks first.
- Risk controls (`risk.rs`, below) gate every opening order. Never add an order path that skips `RiskGuard::check_entry`, and never gate an exit with it.
- Quitting while a strategy still depends on the app (trigger not fired, entry in flight, app-side EOD close) asks first (`AppDelegate.applicationShouldTerminate` in `IBKR_SwiftApp.swift`).
- Never place orders while testing unless the user explicitly asks. `cargo run --example smoke` is read-only.

## Commands

Rust isn't on PATH in non-login shells, so run `source ~/.cargo/env` first.
Only the Rust crate has tests (unit tests inside `src/*.rs`); there is no Swift test target. Targets: Apple Silicon (arm64 only), macOS 27 SDK.
Xcode is normally at `/Applications/Xcode.app`. On the M4 mini it's at `/Volumes/2TB/Applications/Xcode.app` instead. If `xcode-select -p` points at the Command Line Tools, prefix xcodebuild with `DEVELOPER_DIR=<that Xcode>/Contents/Developer`.

```sh
# Rust (from rust/)
cargo build
cargo test                          # all tests
cargo test -p ibkr-core coalesces_ticks   # a single test by name
cargo test -p ibkr-core strategy::   # one module's tests
cargo clippy --all-targets
cargo run --example smoke -- 4002 AAPL   # read-only check against the running Gateway (paper by default; 4001 = live); its risk state goes to a temp file

# Regenerate Swift bindings + xcframework (normally done automatically by the scheme;
# always builds Rust in release, since pre-actions don't reliably see the configuration)
scripts/build-rust.sh

# App
xcodebuild -project "IBKR Swift.xcodeproj" -scheme "IBKR Swift" -configuration Debug build
```

On a fresh clone, run `scripts/build-rust.sh` once before opening Xcode. The `IbkrCore` package's generated sources and xcframework are gitignored, and Xcode can't resolve the package until they exist.

## Architecture

```
SwiftUI views (IBKR Swift/, MainActor by default)
  → AppStore.swift (@Observable; owns IbkrSession + StreamHandles)
    → IbkrCore local Swift package (UniFFI-generated bindings)
      → IbkrCoreFFI.xcframework (Rust staticlib)
        → rust/ibkr-core: IbkrSession { Arc<ibapi::Client> } on a crate-owned Tokio runtime
          → IB Gateway (TCP)
```

- **Rust (`rust/ibkr-core/src/session.rs`)**: everything runs on one `OnceLock` Tokio runtime.
  - Async exports wrap their work in `run(...)`, which spawns onto that runtime. UniFFI's executor only polls a `JoinHandle`, so no `async_runtime` attribute is needed.
  - Streams are spawned tasks that push **full snapshots** to a foreign listener trait: positions (`PositionsListener`), quotes by symbol / option / conid (`QuoteListener`), orders (`OrdersListener`), link status (`ConnectionListener`), strategies (`StrategyListener`, in `strategy.rs`) and risk status (`RiskListener`, in `risk.rs`).
  - Every stream returns a `StreamHandle`. Calling `cancel()` or dropping it aborts the task, and dropping the `ibapi` subscription sends the IB-side cancel.
  - FFI types live in `types.rs`.
- **Placing orders**: `place_order` uses `client.place_order` (not the builder's fire-and-forget `submit()`) and waits up to 5s for IB's first answer. A rejection (`ibapi::Error::Notice`) comes back as an error; no answer yet returns status "Sent". Dropping a `PlaceOrder` subscription does not cancel the order.
- **Gateway drops**: ibapi reconnects by itself but fails every live subscription. The orders and positions streams rerun via `keep_streaming` once `is_connected()` is true again. `subscribe_connection` reports `LinkStatus` (socket loss is seen only by polling `is_connected()`; 1100/1101/1102 come as notices), and Swift re-requests quotes on `RestoredDataLost`.
- **Position P&L**: `subscribe_position_pnl` streams IB's `pnl_single` (unrealized and daily P&L, and market value) for one contract. `AppStore.syncPositionPnl` keeps one stream (`"pnl.<conid>"`) per contract that a strategy holds filled (Protected / Open / Unprotected / Closing), and the strategy rows on the Options screen show it. It's the account's whole position in that contract, measured against IB's average cost, which includes the entry commission.
- **Price history**: `price_history` returns regular-hours trade bars for a `ChartRange` / `BarInterval`. Passing `end` (unix seconds of the oldest bar shown) pages back in time; the Quote chart (`PriceChart` + `ChartInput`) asks for older bars as the user pans or zooms out.
- **Market data**: `connect` calls `switch_market_data_type(Delayed)`. IB still serves live data when the account has a subscription, and the quote's `delayed` flag reports which one you got.
- **Swift isolation**: the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  - The generated bindings therefore live in the separate `IbkrCore/` package, which uses default isolation and Swift 5 mode. Don't move them into the app target.
  - Listener sinks in `AppStore.swift` are `nonisolated` classes that hop to the main queue. They use `DispatchQueue.main.async`, not `Task`, so updates stay in order.
  - `IbkrError`'s generated `errorDescription` is unreadable, so use `AppStore.report(_:)`, which unwraps the message.
- **The project uses a file-system-synchronized group**: new `.swift` files under `IBKR Swift/` compile automatically, with no pbxproj edits. The target also enables `MemberImportVisibility`, so any file that touches IbkrCore types must `import IbkrCore`.

## App (Swift)

- Screens (`SidebarItem` in `ContentView.swift`; views live in `IBKR Swift/Views/`): Account (with the Risk card, `RiskView.swift`), Positions (detail sheet = `PositionDetailView`), Quote (quote cards + pannable chart), Options (strategy ticket, P/L simulator, running strategies = `StrategiesView.swift`), Orders (ticket + list). The sidebar badges working orders and running strategies. When the sidebar is collapsed (`columnVisibility == .detailOnly`), `IconRail` shows the same items and badges as icons at the detail's leading edge.
- `AppStore` keeps one `StreamHandle` per key in `streams` (`"link"`, `"quote"`, `"ticket"`, `"position"`, `"underlying"`, …). Re-subscribing a key cancels the old handle first. `watched` remembers each quote key's symbol so `resubscribeQuotes` can re-request them after `RestoredDataLost`.
- **Auto-connect** (Account menu → Connect Automatically, on by default): `startAutoConnect` runs at launch and retries with backoff from 2s to 30s while Gateway isn't up. Retry failures go to `lastAttemptError` (shown on the "Waiting for IB Gateway" screen), not the error banner. An explicit Disconnect stops it until next launch or a toggle.
- **P/L simulator** (`PnLSimulatorView.swift`, `OptionMath.swift`): Black-Scholes, European, no dividends, a flat 4% rate, one volatility. IV is solved from the option's mid (or last/ask); entry is the ask for buy-now, or the theoretical price at the trigger plus half the spread. The time slider defaults to the ticket's close-at time. The ticket publishes its selections as `SimulationInput` via a binding.
- **Split-view layout**: in `OptionsView`, pin every frame bound on `HSplitView` panes. A pane whose minimum size follows its content (live quotes, hover text) makes AppKit re-run layout mid-layout and abort the app; a nested `VSplitView` did exactly that.
- `Eastern` (in `OptionsView.swift`) holds the US/Eastern date helpers (today, DTE, "HH:MM" today) used by the ticket and the simulator.

## Options strategies (`rust/ibkr-core/src/strategy.rs`, `options.rs`)

One Tokio task per strategy, moving forward only: Arming → Armed / WaitingDelayedData → Entering → Protected / Open → Closing → Closed. The off-ramps are Disarmed, Failed and Unprotected. Swift drives it through `StrategyHandle` (`disarm`, `close_now`) and renders `StrategyUpdate` snapshots. The app (not IB) watches the trigger. Invariants to preserve:

- **Delayed data never fires a trigger**, unless `allow_delayed` is set. `IbkrSession::arm_strategy` forces it off on live ports and on non-`D` accounts, and the UI hides the toggle on live.
- **The trigger must be crossed after arming.** The first last-trade tick is a baseline, and arming fails if that baseline is already through the trigger.
- **Every sell-to-close joins one OCA group (`ReduceWithBlock`).** That covers take-profit, stop, the EOD close (a market order with an IB `TimeCondition`, "YYYYMMDD HH:MM:SS US/Eastern") and close-now. A fill on one shrinks the others by the same amount, so together they never sell more than the position and none can open a short. (`CancelWithBlock` cancelled the stop outright on a *partial* take-profit fill, leaving the rest unprotected.) Never place a closing order outside the group.
  - Exit fills are summed across orders (`ExitFills`); the strategy is Closed only when the whole position is sold, and close-now sells only what's left.
  - Before sizing a close-now / EOD close, the monitor drains every exit status already queued (`Monitor::on_status`), because IB doesn't shrink an OCA member that joins after a fill.
  - If a close-now (or the app-side EOD close) is refused, or ends cancelled / inactive before selling everything, the strategy goes back to its earlier state (Unprotected only if no exit is working) with `can_close` on, so Close Now can be pressed again. Never leave it stuck in Closing.
  - `place_exit` replays the statuses it read while checking acceptance, since a market close can report Filled first.
  - If IB rejects the time-conditioned EOD order, the task falls back to an app-side timer and sets `requires_app`.
- **OCA group names must be unique for the whole account and day** (`oca_group_name`: nanosecond timestamp + entry order id). IB rejects every member of a group whose name has already filled ("OCA group is already filled"), and order ids and strategy ids restart per connection. A reused name once left a filled entry with no exits.
- **Exit prices come from the actual average fill**, rounded with the contract's IB market rule (price bands) via `options::round_to_tick`. Take-profit rounds up and the stop rounds down, floored at one tick. `$` targets are for the whole position (÷ qty × multiplier).
- **OCA siblings get cancelled when the position is sold**, and those cancels can arrive before the fill. Only report Unprotected when every exit is cancelled without the whole position sold.
- **Losing track of the entry is never "Failed".** Only an IB rejection or an unfilled terminal status is Failed; a dropped connection or ended stream reports Unprotected (the market order may still fill). `can_close` tells the UI whether `close_now` will act (only while exits are being monitored).
- **Strategy orders are tracked through ibapi's per-order status taps (`order_status_stream`), never their `place_order` subscriptions.** ibapi keeps one route per order id and a later `place_order` / `cancel_order` on the same id *replaces* it, silently ending the earlier subscription. (Before the switch, the strategy's own "Cancel Entry" did this to its entry tracking.) Taps survive that, so exits can be cancelled or edited from elsewhere.
- Running strategies register their order ids in `OwnedOrders` (removed when the task ends). Manual close / protect refuse positions with working orders in it: the UI closes those with the strategy's Close Now instead.
- **Dropping a `StrategyHandle` before entry disarms it** (the command channel closes). During entry, it does *not* cancel the entry.
- **`resolve_option` trims the expiry date.** `contract_details` returns `last_trade_date_or_contract_month` as "YYYYMMDD HH:MM:SS TZ", which IB rejects on orders (error 10372), so it's cut down to YYYYMMDD.
- **The chain is merged** from IB's per-exchange chains, preferring `trading_class == symbol` (SPY's chain also lists non-standard `2SPY` contracts).
- **Paper end-to-end test:** `cargo run --example strategy_paper -- immediate|trigger`. It refuses non-paper accounts. Both runs passed on 2026-10-22, and IB accepted the time-conditioned EOD order inside the OCA group. Placing orders requires Gateway's "Read-Only API" to be off; otherwise IB returns error 321.

## Fill latency (`rust/ibkr-core/src/latency.rs`)

Each strategy entry (option market buy, including Quick Buy) is timed by a `Stopwatch` in `strategy::enter`.
- IB's order statuses have no timestamps, and execution times are whole seconds. So every phase is timed on Tokio's monotonic clock (microseconds) as the event reaches the app, measured from the submit: sent to Gateway → IB's first status (the ack) → first fill → filled. Trigger → submit is recorded too.
- The result travels in `StrategyUpdate.entry_timing`, and the finished record is appended as JSON lines to `Application Support/Latency/<account>.jsonl`. Swift sets that path with `open_latency_log`, which also returns the history.
- The Options screen shows it on each strategy row and in `LatencySummaryBar` (last, median, p90), with a History… table (`LatencyView.swift`). Slippage is the average fill minus the ask at submit, when an ask was known (with a trigger or a cost limit).
- Logging is best-effort: it must never block or fail an order. Exits (close-now, EOD) aren't timed yet.

## Risk controls (`rust/ibkr-core/src/risk.rs`)

One `RiskGuard` per session (created in `connect`, started by Swift with `start_risk`). Limits: max daily loss and max cost per trade, each off when None. Invariants to preserve:

- **Only opening orders are checked**: strategy entries and manual buys (`place_order`). Exits, position close / protect / modify and cancels never are, because blocking an exit adds risk. For a manual order only the part that opens or adds to a position is checked (`session::opening_quantity`): the position minus what working same-side orders could still fill can be reduced freely, so a halt never blocks an exit and a sell can't open a short unchecked.
- **Strategies are checked twice**: at arming (halt only) and right before the entry is sent (halt, daily P&L, cost). The cost uses the option's ask, kept live while armed (`wait_for_trigger` subscribes to it), or a 3s snapshot (`session::snapshot_ask`) when there's none.
- **Fail closed**:
  - With a daily loss limit set, entries wait for a current P&L reading. `stream_pnl` sets it to None whenever the stream drops.
  - A cost limit with no price refuses the entry.
  - Live sessions (live port or non-`D` account) refuse entries while the guard isn't running.
  - An unreadable state file halts trading for the day.
- **Daily loss** uses IB's account daily P&L (realized + unrealized, `client.pnl`). Reaching −limit halts automatically. IB sends `Double.MAX` for "no value", which is filtered out.
- **A halt lasts until the US/Eastern day rolls over** (`trading_day`, checked on every call and every 30s), not until IB's own P&L reset. It's saved per account (Swift passes `Application Support/Risk/<account>.json`; written via a temp file and rename), so restarts don't lift it. There's no way to lift a halt early. That's deliberate.
- **Tightening a limit applies now; loosening (including turning one off) waits for the next trading day** (`RiskBook::set_limits` keeps the looser request in `pending`).
- **Halting** broadcasts on a `watch` channel. Strategies that haven't bought end Disarmed, and an entry in flight is cancelled like Disarm (a partial fill still gets its exits). It also cancels this client's working manual buy orders (`cancel_manual_buys`), except buys that only cover a short (a buy-to-close, or a stop / take-profit on a short): those are exits. TWS and other clients' orders are untouched.
- The pure rules live in `RiskBook` (unit tested). Swift mirrors them in `AppStore.entryProblem` for instant feedback only; the Rust side decides.
- Paper check: `cargo run --example strategy_paper -- halt` arms an untriggerable strategy, halts, and verifies the disarm and the refusals. It places nothing unless the guard is broken (then it cancels the $1 limit it sent). The halt there isn't saved, since the example doesn't start the guard.

## Orders list (`rust/ibkr-core/src/orders.rs`)

The order list (the `orders` stream) keeps every order IB reports instead of dropping finished ones. It's seeded from `all_open_orders()` plus `completed_orders(false)` (today's filled, cancelled and rejected orders, including manual TWS ones), then updated from `order_update_stream()`.

- Orders are keyed by **perm id**, because completed orders placed outside the API carry order id 0 or -1. An order seen before IB assigns a perm id gets a provisional key, which migrates once the perm id arrives.
- `OrderStatusGroup` buckets IB's statuses for the Orders screen filter: Open, Filled, Cancelled, Inactive and Other.
- Completed orders report `total_quantity` 0 and can echo stale limit prices, which `upsert` normalizes. They carry no fill price, so today's executions are seeded too (`apply_execution`, by perm id).
- The update stream is read without `filter_data()`: order-bound notices carry IB's rejection reasons, which `Book::note` attaches to this client's order (or holds until it arrives). A status that arrives before its order is held too.
- **Timeline**: `OrderInfo.timeline` holds the system-clock times (unix ms) at which the app saw each event: submitted (`orders::note_submit`, called before every new `place_order`, never on a modify), first seen, acknowledged (IB's first message), first fill, filled, and ended. `executions` lists each fill with IB's execution time (whole seconds, IB's only per-event time) and when it arrived. Orders loaded at connect are `from_snapshot`, so their earlier events aren't timed. A process-wide `Memory` keeps timings across book reloads (Refresh, reconnects). Clicking a row on the Orders screen opens `OrderDetailView`.
- `OrderInfo.client_id`: order ids are only unique per client id, so the UI offers Cancel only for this connection's orders.
- Swift toasts fills, partial fills, cancels and rejections by diffing snapshots (`AppStore.ordersChanged`); the first snapshot after connecting is the baseline.

## Realized P&L ledger (`rust/ibkr-core/src/ledger.rs`)

The Orders screen shows realized P/L net of fees (`PnLTallyView.swift`) with a Day / Week / Month / Year picker. Week starts Monday, and all periods use US/Eastern days.
- **IB's API only returns about 7 days of executions**, so `subscribe_ledger` keeps a local ledger of fills and commission reports per account (Swift passes `Application Support/Ledger/<account>.json`; written via a temp file and rename). It backfills IB's window on connect, then polls every 10s with `executions(last_n_days)`. This polling works for every client, including TWS. It doesn't use `order_update_stream`, which allows only one subscriber, and `orders.rs` holds it.
- **Net is IB's `realized_pnl` per closing fill**, which already subtracts the commissions on both legs. Don't subtract commissions again. "Commissions & fees" is the sum over every fill in the period, open positions included. IB's Double.MAX "no value" is filtered out.
- Fills are keyed by exec id without its correction suffix, and the later correction wins. A commission report can arrive before or after its fill.
- **Completeness:** `since` / `covered_through` track which days were actually read. Each read goes back to the last day covered, up to IB's 7-day maximum. If the app was off for longer, `since` restarts and the tally shows "Recorded since …". An unreadable ledger file is reported and never overwritten.
- Importing older history from IB Flex statements is planned but not built.

## Position actions (`rust/ibkr-core/src/position.rs`)

- **Close**: a whole-position limit order at the capped price the user reviewed (bid − cap to sell, ask + cap to buy; defaults 5% options, 0.5% stocks), Day TIF.
  - It refuses if TWS or another client has working orders on the contract.
  - Otherwise it cancels this client's working orders there and waits for IB to confirm each cancel. It aborts if any of them filled meanwhile, since IB's position report can lag a fill.
  - Then it re-reads the quantity from IB, which must equal what the user reviewed (`expected_quantity`).
- **Protect**: take-profit and/or stop (optionally stop-limit), in one `ReduceWithBlock` OCA group, GTC. It's only allowed when the contract has no working orders; edit those instead.
- **Modify**: only this connection's working orders. It re-sends the order as IB currently reports it (so an OCA-reduced quantity stays reduced) with the new limit/aux price, rounded to the nearest tick.
- Contracts are resolved by conid with exchange SMART (`options::resolve_contract_id`). Stocks report no multiplier, so it defaults to 1. `Position.average_cost` includes the multiplier.

## Build pipeline gotchas

- Xcode builds local packages **before** a target's run-script phases. That's why `scripts/build-rust.sh` runs as a **build pre-action** in the shared scheme (`xcshareddata/xcschemes/IBKR Swift.xcscheme`) and not as a build phase.
- Pre-action output goes to `rust/target/build-rust.log`. On failure the script touches `rust/target/build-rust.failed`, and the app target's "Verify Rust Build" phase then fails the build. This phase needs `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
- `build-rust.sh` skips regenerating when `libibkr_core.a` hasn't changed (stamp file `IbkrCoreFFI.xcframework/.source`). It assembles the xcframework by hand, without `xcodebuild -create-xcframework`, and builds arm64 only.
- Module names come from `rust/ibkr-core/uniffi.toml` (`IbkrCore` / `IbkrCoreFFI`).
- Do not edit `IbkrCore/Sources/IbkrCore/IbkrCore.swift` or the xcframework; they're regenerated.
- The app sandbox is on, and outgoing connections are allowed via `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`.

## ibapi notes

- The `ibapi` 5.x source is the best reference: `~/.cargo/registry/src/*/ibapi-5.*/examples/async/`.
- The order builder is `client.order(&contract).buy(q).limit(px).time_in_force(..)`; `.build()` gives an `Order` for `client.place_order`. Its `.submit()` is fire-and-forget, so rejections never reach the caller: don't use it.
- `cancel_order(id, "")` returns a subscription. The code waits up to 3s for the first reply so rejections surface as errors.
- Gateway must have "Enable ActiveX and Socket Clients" on and 127.0.0.1 trusted. For orders, "Read-Only API" must be unchecked.
