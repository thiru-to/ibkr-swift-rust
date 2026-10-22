# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Minimal native macOS client for a locally running IB Gateway. The Rust core wraps the `ibapi` crate (async/Tokio), and a SwiftUI app sits on top, bridged with UniFFI.

## Safety

- **Port 4001 is the LIVE Gateway port (real money)**; 4002 is paper. The **Account** menu selects Live or Paper, which sets the port; the choice persists in UserDefaults and defaults to Paper.
- `AppStore.isLive` is deliberately conservative: it's true if the mode is Live, *or* the port is a live port (`IbkrSession::is_live()`: 4001 or 7496), *or* the account id doesn't start with `D` (IB paper ids look like `DU…`). A Paper/live mismatch shows a warning.
- Every order submit in `OrdersView.swift` goes through a confirmation dialog that shows the account and LIVE/PAPER. Keep that step.
- Never place orders while testing unless the user explicitly asks. `cargo run --example smoke` is read-only.

## Commands

Rust isn't on PATH in non-login shells, so run `source ~/.cargo/env` first.
Xcode is at `/Volumes/2TB/Applications/Xcode.app`. If `xcode-select` still points at the Command Line Tools, prefix xcodebuild with `DEVELOPER_DIR=/Volumes/2TB/Applications/Xcode.app/Contents/Developer`.

```sh
# Rust (from rust/)
cargo build
cargo test                          # all tests
cargo test -p ibkr-core coalesces   # a single test by name
cargo clippy --all-targets
cargo run --example smoke -- 4001 AAPL   # read-only check against the running Gateway

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
  - Streams (positions, quote, orders) are spawned tasks that push **full snapshots** to a foreign listener trait (`PositionsListener`, `QuoteListener`, `OrdersListener`).
  - Every stream returns a `StreamHandle`. Calling `cancel()` or dropping it aborts the task, and dropping the `ibapi` subscription sends the IB-side cancel.
  - FFI types live in `types.rs`.
- **Orders stream**: it opens `order_update_stream()` *before* seeding from `all_open_orders()`, so nothing placed during seeding is missed. It drops orders in terminal states (Filled, Cancelled, ApiCancelled, Inactive).
- **Market data**: `connect` calls `switch_market_data_type(Delayed)`. IB still serves live data when the account has a subscription, and the quote's `delayed` flag reports which one you got.
- **Swift isolation**: the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  - The generated bindings therefore live in the separate `IbkrCore/` package, which uses default isolation and Swift 5 mode. Don't move them into the app target.
  - Listener sinks in `AppStore.swift` are `nonisolated` classes that hop to the main queue. They use `DispatchQueue.main.async`, not `Task`, so updates stay in order.
  - `IbkrError`'s generated `errorDescription` is unreadable, so use `AppStore.report(_:)`, which unwraps the message.
- **The project uses a file-system-synchronized group**: new `.swift` files under `IBKR Swift/` compile automatically, with no pbxproj edits. The target also enables `MemberImportVisibility`, so any file that touches IbkrCore types must `import IbkrCore`.

## Build pipeline gotchas

- Xcode builds local packages **before** a target's run-script phases. That's why `scripts/build-rust.sh` runs as a **build pre-action** in the shared scheme (`xcshareddata/xcschemes/IBKR Swift.xcscheme`) and not as a build phase.
- Pre-action output goes to `rust/target/build-rust.log`. On failure the script touches `rust/target/build-rust.failed`, and the app target's "Verify Rust Build" phase then fails the build. This phase needs `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
- `build-rust.sh` skips regenerating when `libibkr_core.a` hasn't changed (stamp file `IbkrCoreFFI.xcframework/.source`). It assembles the xcframework by hand, without `xcodebuild -create-xcframework`, and builds arm64 only.
- Module names come from `rust/ibkr-core/uniffi.toml` (`IbkrCore` / `IbkrCoreFFI`).
- Do not edit `IbkrCore/Sources/IbkrCore/IbkrCore.swift` or the xcframework; they're regenerated.
- The app sandbox is on, and outgoing connections are allowed via `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`.

## ibapi notes

- The `ibapi` 5.x source is the best reference: `~/.cargo/registry/src/*/ibapi-5.*/examples/async/`.
- The order builder is `client.order(&contract).buy(q).limit(px).time_in_force(..).submit()`, which returns an `OrderId` (`.value()` gives the i32).
- `cancel_order(id, "")` returns a subscription. The code waits up to 3s for the first reply so rejections surface as errors.
- Gateway must have "Enable ActiveX and Socket Clients" on and 127.0.0.1 trusted. For orders, "Read-Only API" must be unchecked.
