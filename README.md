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
- Apple Maps share extension:
  - choose a place in Apple Maps;
  - tap **Share → PlaceDrift**;
  - the extension extracts the coordinate and forwards it over a loopback-only bridge to the running PlaceDrift session;
  - iOS 26/27 `https://maps.apple/p/...` links are handled by inspecting the redirect chain for the expanded coordinate URL.
- Background keep-alive for the CoreDevice/DVT session using Core Location with `showsBackgroundLocationIndicator = false` when **Always** authorization is granted.
- URL scheme remains available as a fallback:
  - `placedrift://set?lat=34.052235&lon=-118.243683`
  - `placedrift://clear`
  - `placedrift://pair`

Shortcuts/App Intents are no longer part of PlaceDrift.

## Maps sharing setup

1. Pair PlaceDrift with the iPhone.
2. Leave **Enable Maps sharing** on.
3. Grant PlaceDrift **Always** location access when requested. This is used to keep the CoreDevice session and local share receiver available while PlaceDrift is in the background; the app does not store the real coordinates delivered by Core Location.
4. Keep Clash Mi connected with the TUN loopback address below.
5. In Apple Maps, share any place to **PlaceDrift**.

If PlaceDrift has been force-quit, reopen it before using the share extension so the local receiver and background session can start again.

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

The unsigned IPA contains the embedded `PlaceDriftShare.appex` and can then be signed with the user's preferred signing workflow. The main app and extension both need to remain signed as part of the same installed bundle.
