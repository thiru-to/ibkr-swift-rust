# IBKR Swift

A minimal native macOS client for a locally running **Interactive Brokers IB Gateway**.
The trading logic is a Rust core built on the [`ibapi`](https://crates.io/crates/ibapi) crate (async/Tokio), and the UI is SwiftUI. UniFFI bridges the two.

> **This app can place real orders.** Port 4001 is IB Gateway's *live* port and trades real money; 4002 is paper. The app starts in Paper mode. Test against a paper account first.

## Features

- **Account**: summary values (net liquidation, cash, buying power, P&L) for the connected account.
- **Positions**: live positions with value and P&L. A position's detail sheet lists its working orders and can:
  - close the whole position with a price-capped limit order,
  - add a take-profit and/or stop (optionally stop-limit) as one OCA group,
  - edit the price of a working order this connection placed.
- **Quote**: bid/ask/last for a symbol, with a pannable, zoomable price chart (line or candles, 1m to daily bars). Older history loads as you scroll back.
- **Options**: a strategy ticket for single-leg option buys.
  - Pick the underlying, expiry and strike from IB's chain.
  - Enter immediately, or when the underlying crosses a trigger price (watched by the app).
  - Exits: take-profit and stop (in % or $) and an optional end-of-day close. All of them share one OCA group at IB, so together they can never sell more than you hold.
  - A **P/L simulator** charts estimated P/L against the underlying's price at a chosen time and at expiry (Black-Scholes at the option's implied volatility). It's an estimate only and never places orders.
  - Running strategies show their state (armed, entering, protected, closing, closed) and can be disarmed or closed now.
- **Orders**: a stock order ticket (buy/sell, market or limit, Day or GTC) with price sanity checks, and today's orders from every client (including ones placed in TWS), filterable by status. Cancel works on orders this connection placed. Toasts announce fills, partial fills, cancels and rejections.
- **Connection**: connects automatically at launch and keeps retrying until Gateway is up. It recovers after Gateway drops and reconnects.

### Safety rails

- Every order, position action and strategy arm goes through a review step showing the account and **LIVE / PAPER**. There's no Return shortcut on the final button.
- The app treats a session as live if the mode is Live, the port is a live port (4001 / 7496), *or* the account id isn't a paper id (`DU…`). A mismatch shows a warning.
- On live sessions, strategy triggers never fire on delayed market data.
- The Rust core re-checks position actions against IB before sending (quantity unchanged, no conflicting working orders from other clients).
- Quitting while a strategy still depends on the app (trigger not fired yet, entry in flight) asks for confirmation. Protected positions keep their exit orders at IB.

## Requirements

- An Apple Silicon Mac (the Rust library is built for arm64 only), macOS 27 or later
- Xcode with the macOS 27 SDK
- Rust via [rustup](https://rustup.rs) with the `aarch64-apple-darwin` target
- IB Gateway (or TWS), logged in, with API access set up:
  - **Configure → Settings → API → Settings**: turn on *Enable ActiveX and Socket Clients* and add `127.0.0.1` to the trusted IPs.
  - To place orders, **uncheck *Read-Only API***. Otherwise IB rejects every order with error 321.
  - Ports: Gateway live **4001**, paper **4002** (TWS: 7496 / 7497).

Without a market data subscription, IB serves delayed quotes; the app labels them **DELAYED**.

## Getting started

```sh
git clone https://github.com/thiru-to/ibkr-swift-rust.git
cd ibkr-swift-rust

# One time: build the Rust core and generate the Swift bindings + xcframework.
# Xcode can't resolve the IbkrCore package until these exist (they're gitignored).
scripts/build-rust.sh

open "IBKR Swift.xcodeproj"
```

Then build and run the **IBKR Swift** scheme. After that, the scheme rebuilds the Rust core on every build (a pre-action runs `scripts/build-rust.sh`).

In the app, choose **Account → Trading Mode** (Paper or Live) while disconnected. That sets the port. **Account → Connect Automatically** toggles connecting at launch. Host, port and client id can be changed in the toolbar and are remembered.

### Command line

```sh
# App
xcodebuild -project "IBKR Swift.xcodeproj" -scheme "IBKR Swift" -configuration Debug build

# Rust core (from rust/)
cargo build
cargo test
cargo clippy --all-targets
```

If `xcodebuild` complains about the Command Line Tools, point `DEVELOPER_DIR` at your Xcode, for example `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

### Checking against a running Gateway

```sh
cd rust

# Read-only: connects, prints the account summary, positions, price history and live quotes. Never places orders.
cargo run --example smoke                 # [port] [symbol], defaults 4002 AAPL; pass 4001 for live

# PAPER ONLY: arms a real strategy (1 SPY 0DTE ATM call, TP +50%, SL -30%, EOD 15:50),
# waits until it's protected, then closes it. Refuses live ports and non-paper accounts.
cargo run --example strategy_paper -- immediate
cargo run --example strategy_paper -- trigger
```

## Architecture

```
SwiftUI views (IBKR Swift/)
  → AppStore.swift            app state; owns the session and its streams
    → IbkrCore                local Swift package with the UniFFI-generated bindings
      → IbkrCoreFFI.xcframework   the Rust static library
        → rust/ibkr-core          IbkrSession on a Tokio runtime, wrapping ibapi::Client
          → IB Gateway (TCP)
```

- Rust exposes async calls (connect, place / cancel / modify orders, option chains, price history, position actions) and **streams** (connection status, positions, quotes, orders, strategies). Each stream pushes full snapshots to a Swift listener and returns a `StreamHandle`; cancelling or dropping it ends the IB subscription.
- Each option strategy runs as its own Rust task: Arming → Armed → Entering → Protected → Closing → Closed, with Disarmed, Failed and Unprotected as the off-ramps.
- Swift views run on the main actor. The generated bindings live in a separate package with default isolation, and listener callbacks hop to the main queue.

### Repository layout

```
IBKR Swift/                 SwiftUI app (AppStore.swift, ContentView.swift, Views/)
IBKR Swift.xcodeproj/       Xcode project; the shared scheme runs build-rust.sh as a pre-action
IbkrCore/                   Swift package wrapping the generated bindings (generated files are gitignored)
rust/ibkr-core/src/
  session.rs                IbkrSession: connection, streams, orders, the FFI surface
  strategy.rs               option strategy state machine (trigger, entry, OCA exits)
  options.rs                chains, contract resolution, tick rounding
  orders.rs                 order book behind the Orders screen
  position.rs               close / protect / modify for positions
  types.rs                  types shared with Swift
rust/ibkr-core/examples/    smoke (read-only) and strategy_paper (paper-only) checks
scripts/build-rust.sh       builds Rust, generates bindings, assembles the xcframework
```

## Troubleshooting

- **Xcode can't find `IbkrCore` / missing package product**: run `scripts/build-rust.sh`, then reopen the project or reset package caches.
- **The build fails at "Verify Rust Build"**: the Rust pre-action failed. See `rust/target/build-rust.log`.
- **"Waiting for IB Gateway"**: Gateway isn't running or logged in, the port doesn't match the mode, or 127.0.0.1 isn't trusted in the API settings.
- **Every order is rejected with error 321**: Gateway's *Read-Only API* is still on.
- **Quotes say DELAYED**: the account has no live data subscription for that product. Delayed data never fires a strategy trigger on a live account.

## Development notes

Contributor and AI-assistant notes, including invariants the order code relies on, are in [CLAUDE.md](CLAUDE.md).

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Interactive Brokers. It is provided as is, without warranty of any kind; you are responsible for every order it places.
