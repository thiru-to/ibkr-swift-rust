#!/bin/bash
# Builds the Rust core and regenerates the Swift package inputs in IbkrCore/:
#   IbkrCore/Sources/IbkrCore/IbkrCore.swift   (UniFFI bindings)
#   IbkrCore/IbkrCoreFFI.xcframework           (static lib + C header + modulemap)
# Run by the "IBKR Swift" scheme's build pre-action; safe to run by hand.
# Always builds cargo's release profile: scheme pre-actions don't reliably see the
# configuration being built, and an incremental release build only takes a few seconds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST="$ROOT/rust"
PKG="$ROOT/IbkrCore"
XCF="$PKG/IbkrCoreFFI.xcframework"
FAILED="$RUST/target/build-rust.failed"
TARGET=aarch64-apple-darwin

mkdir -p "$RUST/target"
trap 'touch "$FAILED"' ERR
rm -f "$FAILED"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

cd "$RUST"
cargo build -p ibkr-core --lib --release --target "$TARGET"
LIB="$RUST/target/$TARGET/release/libibkr_core.a"

# cargo is incremental; skip regeneration when the library hasn't changed.
STAMP="$XCF/.source"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$LIB" ] && [ ! "$LIB" -nt "$STAMP" ]; then
  echo "IbkrCore bindings up to date"
  exit 0
fi

GEN="$RUST/target/uniffi-swift"
rm -rf "$GEN" && mkdir -p "$GEN"
cargo run -q -p ibkr-core --bin uniffi-bindgen -- \
  generate --library "$LIB" --language swift --out-dir "$GEN"

mkdir -p "$PKG/Sources/IbkrCore"
cp "$GEN/IbkrCore.swift" "$PKG/Sources/IbkrCore/IbkrCore.swift"

# Hand-assembled xcframework (one macOS arm64 slice); avoids needing xcodebuild here.
rm -rf "$XCF"
SLICE="$XCF/macos-arm64"
mkdir -p "$SLICE/Headers"
cp "$LIB" "$SLICE/libibkr_core.a"
cp "$GEN/IbkrCoreFFI.h" "$SLICE/Headers/"
cp "$GEN/IbkrCoreFFI.modulemap" "$SLICE/Headers/module.modulemap"
cat > "$XCF/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libibkr_core.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libibkr_core.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
echo "$LIB" > "$STAMP"
echo "IbkrCore bindings regenerated"
