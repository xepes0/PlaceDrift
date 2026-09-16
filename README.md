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

PlaceDrift does not create or own a VPN. A compatible TUN/proxy app provides the self-device loopback transport.

## Current test status

The full PlaceDrift path has been validated on physical iOS 27 hardware with Clash Mi configured with `loopback-address: 10.7.0.1`:

```text
Apple Maps / manual coordinates
  → PlaceDrift
  → Clash Mi TUN loopback 10.7.0.1
  → RemotePairing
  → Pair Verify
  → TLS-PSK
  → RSD
  → DVT
  → LocationSimulation
```

Pairing, Apple Maps sharing, RemotePairing discovery, simulated-location activation and subsequent location switching have all been confirmed on-device.

If the active VPN/TUN app does not provide an equivalent self-device loopback path, PlaceDrift can discover the RemotePairing service but the TCP connection to `10.7.0.1:<RemotePairing port>` will time out before Pair Verify. In that case, switch back to a compatible TUN configuration instead of deleting the saved pairing record.

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

## Clash Mi configuration

The validated Clash Mi configuration includes:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

Keep Clash Mi connected while using PlaceDrift. PlaceDrift itself does not occupy the VPN slot.

Pairing state is independent of transport state. If PlaceDrift reports a RemotePairing connection timeout after switching VPN/TUN apps, restore a compatible `loopback-address: 10.7.0.1` TUN setup and retry; pairing again is normally unnecessary.

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
