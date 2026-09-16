# PlaceDrift

PlaceDrift is an iOS CoreDevice location-control app built around the transport path already validated on physical iOS 27 hardware.

```text
PlaceDrift
  → Clash Mi TUN `loopback-address: 10.7.0.1`
  → RemotePairing
  → Pair Verify
  → TLS-PSK
  → RSD
  → DVT
  → LocationSimulation
```

PlaceDrift does not create or own a VPN. Clash Mi remains the single VPN/TUN owner.

## Features

- First-run PIN pairing through **Settings → Privacy & Security → Developer Mode → Pair with Host**.
- Pairing record stored in Keychain.
- Automatic `_remotepairing._tcp` discovery and identity validation.
- Set, update and clear simulated location.
- Simplified Chinese UI.
- Shortcuts actions:
  - pass a Shortcuts **Location** directly to PlaceDrift;
  - pass latitude and longitude;
  - restore real location.
- URL scheme:
  - `placedrift://set?lat=34.052235&lon=-118.243683`
  - `placedrift://clear`
  - `placedrift://pair`

## Runtime requirement

Clash Mi must be connected with:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

## Build

Requirements:

- macOS + Xcode
- XcodeGen
- Rust toolchain

Run:

```bash
./scripts/build-app.sh
```

Output:

```text
.build/artifacts/PlaceDrift-unsigned.ipa
```

The unsigned IPA can then be signed with the user's preferred signing workflow.
