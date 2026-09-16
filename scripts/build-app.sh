#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_TARGET="aarch64-apple-ios"
RUST_OUT="$ROOT/.build/coredevice-app"
VENDOR="$ROOT/app/Vendor"
DERIVED="$ROOT/.build/xcode-placedrift"
ARTIFACT="$ROOT/.build/artifacts"
ICON_DIR="$ROOT/app/App/Assets.xcassets/AppIcon.appiconset"

rustup target add "$RUST_TARGET"
cargo build \
  --manifest-path "$ROOT/native/coredevice/Cargo.toml" \
  --release \
  --target "$RUST_TARGET" \
  --target-dir "$RUST_OUT"

mkdir -p "$VENDOR/include" "$ARTIFACT" "$ICON_DIR"
cp "$RUST_OUT/$RUST_TARGET/release/libplacedrift_coredevice_engine.a" "$VENDOR/"
cp "$ROOT/native/coredevice/include/placedrift_coredevice.h" "$VENDOR/include/"

# Generate the original PlaceDrift app icon on the macOS/Xcode builder so the
# repository can keep the icon source as text while the IPA still contains all
# required PNG sizes.
swift "$ROOT/scripts/generate-app-icon.swift" "$ICON_DIR"

cd "$ROOT/app"
xcodegen generate

xcodebuild \
  -project PlaceDrift.xcodeproj \
  -scheme PlaceDrift \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP="$DERIVED/Build/Products/Release-iphoneos/PlaceDrift.app"
test -d "$APP"

rm -rf "$ARTIFACT/Payload"
mkdir -p "$ARTIFACT/Payload"
cp -R "$APP" "$ARTIFACT/Payload/"

(
  cd "$ARTIFACT"
  rm -f PlaceDrift-unsigned.ipa
  zip -qry PlaceDrift-unsigned.ipa Payload
)

echo "Built: $ARTIFACT/PlaceDrift-unsigned.ipa"
