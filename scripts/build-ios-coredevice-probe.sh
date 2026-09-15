#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_TARGET="aarch64-apple-ios"
RUST_OUT="$ROOT/.build/coredevice"
VENDOR="$ROOT/ios-probe/Vendor"
DERIVED="$ROOT/.build/xcode"
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

cd "$ROOT/ios-probe"
xcodegen generate

xcodebuild \
  -project WLOCCoreDeviceProbe.xcodeproj \
  -scheme WLOCCoreDeviceProbe \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="$DERIVED/Build/Products/Release-iphoneos/WLOCCoreDeviceProbe.app"
test -d "$APP"
rm -rf "$ARTIFACT/Payload"
mkdir -p "$ARTIFACT/Payload"
cp -R "$APP" "$ARTIFACT/Payload/"
(
  cd "$ARTIFACT"
  rm -f WLOCCoreDeviceProbe-unsigned.ipa
  zip -qry WLOCCoreDeviceProbe-unsigned.ipa Payload
)

echo "Built: $ARTIFACT/WLOCCoreDeviceProbe-unsigned.ipa"
