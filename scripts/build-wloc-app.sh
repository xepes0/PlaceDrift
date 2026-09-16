#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_TARGET="aarch64-apple-ios"
RUST_OUT="$ROOT/.build/coredevice-app"
VENDOR="$ROOT/wloc-app/Vendor"
DERIVED="$ROOT/.build/xcode-wloc-app"
ARTIFACT="$ROOT/.build/artifacts"

rustup target add "$RUST_TARGET"
cargo build \
  --manifest-path "$ROOT/native/coredevice/Cargo.toml" \
  --release \
  --target "$RUST_TARGET" \
  --target-dir "$RUST_OUT"

mkdir -p "$VENDOR/include" "$ARTIFACT"
cp "$RUST_OUT/$RUST_TARGET/release/libwloc_coredevice_engine.a" "$VENDOR/"
cp "$ROOT/native/coredevice/include/wloc_coredevice.h" "$VENDOR/include/"

cd "$ROOT/wloc-app"
xcodegen generate

xcodebuild \
  -project WLOC.xcodeproj \
  -scheme WLOC \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="$DERIVED/Build/Products/Release-iphoneos/WLOC.app"
test -d "$APP"
rm -rf "$ARTIFACT/Payload"
mkdir -p "$ARTIFACT/Payload"
cp -R "$APP" "$ARTIFACT/Payload/"
(
  cd "$ARTIFACT"
  rm -f WLOC-unsigned.ipa
  zip -qry WLOC-unsigned.ipa Payload
)

echo "Built: $ARTIFACT/WLOC-unsigned.ipa"
