# WLOC App Mainline

This directory is the product-oriented iOS app mainline for WLOC.

The validated transport is:

```text
WLOC App
  -> 10.7.0.1 via Clash Mi `loopback-address`
  -> RemotePairing
  -> Pair Verify
  -> TLS-PSK
  -> RSD
  -> DVT
  -> LocationSimulation
```

The app does **not** start a VPN. Clash Mi remains the only VPN/TUN owner.

## First product milestone

- Native SwiftUI app shell.
- First-run PIN pairing through Developer Mode > Pair with Host.
- Pairing record stored in Keychain.
- Automatic `_remotepairing._tcp` discovery and pairing-record identity match.
- Set/update/clear simulated location through the already validated Rust CoreDevice engine.
- `wloc://set?lat=<lat>&lon=<lon>` and `wloc://clear` deep links.

## Build

Requirements on macOS:

- Rust toolchain with `aarch64-apple-ios` target.
- Xcode.
- XcodeGen.

Run:

```bash
./scripts/build-wloc-app.sh
```

The unsigned IPA is written to `.build/artifacts/WLOC-unsigned.ipa`.

## Signing / runtime prerequisite

Sign the IPA with a profile that can run the app on the target iPhone. No Network Extension entitlement is required by this app mainline because it does not own a VPN tunnel.

Clash Mi must be connected with:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

`browser-wasm/` remains a research branch/experiment and is not the product execution path.