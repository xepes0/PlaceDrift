# PlaceDrift

PlaceDrift is an iOS CoreDevice location-control app for iOS 27+.

```text
Apple Maps / Shortcuts / manual coordinates
  → PlaceDrift
  → compatible TUN self-loop `10.7.0.1`
  → RemotePairing
  → Pair Verify
  → TLS-PSK
  → RSD
  → DVT
  → LocationSimulation
```

PlaceDrift does not create or own a VPN. A compatible TUN/proxy app provides the self-device loopback transport.

## Current test status

The complete location path has been validated on a physical iOS 27 device with Clash Mi and:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

Validated on-device:

- CoreDevice RemotePairing and saved pairing record.
- Pair Verify → TLS-PSK → RSD → DVT → LocationSimulation.
- Apple Maps Share → PlaceDrift → immediate location switching.
- Manual latitude/longitude updates while the CoreDevice session stays active.
- Restore real location.

If the active VPN/TUN app does not provide an equivalent self-loop, PlaceDrift may still discover `_remotepairing._tcp` but the TCP connection to `10.7.0.1:<RemotePairing port>` will time out before Pair Verify. In that case, restore a compatible TUN configuration; deleting the saved pairing record is normally unnecessary.

## PlaceDrift 0.2.1

This test build keeps the Maps-share/background path and adds:

- clearer Chinese transport errors;
- a persistent `10.7.0.1` transport indicator and app version in the status section;
- clearer runtime guidance when the active TUN does not provide the self-loop;
- App Shortcuts restored alongside Apple Maps sharing;
- coordinate fields update automatically after Maps sharing or a Shortcuts location action.

## Apple Maps sharing

1. Pair PlaceDrift with the iPhone.
2. Leave **Enable Maps sharing** on.
3. Grant PlaceDrift **Always** location access when requested. It is used to keep the CoreDevice session and local share receiver available in the background; PlaceDrift does not store the real coordinates delivered by Core Location.
4. Keep a compatible TUN/proxy app connected with `loopback-address: 10.7.0.1` enabled.
5. In Apple Maps, choose a place and use **Share → PlaceDrift**.

The embedded `PlaceDriftShare.appex` extracts coordinates from shared Maps content and forwards them over a loopback-only bridge to the running PlaceDrift session. iOS 26/27 `https://maps.apple/p/...` links are handled by resolving the expanded coordinate URL.

If PlaceDrift has been force-quit, reopen it before using the share extension so the local receiver and background session can start again.

## Shortcuts

PlaceDrift 0.2.1 also exposes App Intents for:

- **Set PlaceDrift Location** — pass a Shortcuts `Location` directly;
- **Set PlaceDrift Coordinates** — pass latitude and longitude as numbers;
- **Restore Real Location**.

The Apple Maps share path does not require Shortcuts; both methods can coexist.

## URL scheme

```text
placedrift://set?lat=34.052235&lon=-118.243683
placedrift://clear
placedrift://pair
```

## Runtime requirement

The validated configuration uses Clash Mi:

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

Other TUN/proxy apps can only be used if they provide an equivalent self-device loopback route to `10.7.0.1`. PlaceDrift itself does not occupy the VPN slot.

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

The unsigned IPA contains the embedded `PlaceDriftShare.appex`. The main app and extension must both remain signed as part of the same installed bundle.

## Privacy

Pairing records and CoreDevice credentials remain on-device and are stored in Keychain. Do not upload pairing records, AltIRK material or private device credentials to GitHub, web pages or analytics services.
