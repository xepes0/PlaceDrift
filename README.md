# PlaceDrift

PlaceDrift is a native iOS CoreDevice location-simulation app for iOS 27+.

The CoreDevice protocol path is:

```text
PlaceDrift
  → local self-device transport
  → RemotePairing
  → Pair Verify
  → TLS-PSK
  → RSD
  → DVT
  → LocationSimulation
```

PlaceDrift does not create or own a VPN. The product goal is to keep an existing proxy/VPN app such as Clash Mi as the only TUN owner.

## Current test status

The RemotePairing/CoreDevice/LocationSimulation stack has been validated on physical iOS 27 hardware with a LocalDevVPN-compatible self-device path.

The first PlaceDrift build is currently validating whether Clash Mi's `loopback-address: 10.7.0.1` can provide the same self-device transport on iOS. On the first physical PlaceDrift test, pairing, Apple Maps sharing and RemotePairing service discovery succeeded, but the TCP connection to `10.7.0.1:<RemotePairing port>` timed out before Pair Verify. This transport issue is under active investigation.

## Features

- First-run PIN pairing through **Settings → Privacy & Security → Developer Mode → Pair with Host**.
- Pairing record stored in Keychain.
- Automatic `_remotepairing._tcp` discovery and pairing-record identity validation.
- Set, update and clear simulated location.
- Simplified Chinese UI.
- Apple Maps share receiver: share a place/location directly to PlaceDrift.
- Shortcuts actions:
  - pass a Shortcuts **Location** directly to PlaceDrift;
  - pass latitude and longitude;
  - restore real location.
- URL scheme:
  - `placedrift://set?lat=34.052235&lon=-118.243683`
  - `placedrift://clear`
  - `placedrift://pair`

## Clash Mi test configuration

The current Clash Mi experiment uses:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

Do not treat this route as universally working on iOS yet. Pairing state is independent of transport state, so a transport failure does not require pairing again.

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

## Privacy

Pairing records and CoreDevice credentials remain on-device and are stored in Keychain. Do not upload pairing records, AltIRK material or private device credentials to GitHub, web pages or analytics services.
