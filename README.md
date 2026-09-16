# PlaceDrift

PlaceDrift is an iOS CoreDevice location-control app for iOS 27+.

```text
Apple Maps / Amap / Baidu Maps / Shortcuts / manual coordinates
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

The complete location path has been validated on a physical iOS 27 device with `10.7.0.1` self-loop transport.

### Confirmed working

- **LocalDevVPN** — confirmed working.
- **Clash Mi** — confirmed working with `loopback-address: 10.7.0.1`.
- **Clash** — confirmed working with `loopback-address: 10.7.0.1`.
- **Karing** — confirmed working.

### Tested but not yet compatible with the current configuration

- **Loon** — the tested TUN Only configuration can make a TCP socket appear reachable, but the real RemotePairing / Pair Verify path does not complete.
- **Surge** — the tested configuration can also produce a false-positive TCP-ready state, while the real RemotePairing / Pair Verify path fails.

These results describe the tested configurations only; they do not rule out a future Loon or Surge configuration that implements the required self-device reflection.

### Pending

- **Egern**
- Other iOS VPN/TUN tools that can provide an equivalent `10.7.0.1` self-device loopback route.

## TUN configuration examples

### Clash Mi / Clash

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

### Karing

The physical-device test that passed used the following minimal TUN settings:

```text
TUN: enabled
IPv4: 10.20.0.1/30
Loopback Address: 10.7.0.1
Stack: gvisor
Outbound: DIRECT
```

Make sure `10.7.0.1` is not excluded by a broad route such as `10.0.0.0/8`.

Equivalent sing-box-style TUN configuration:

```json
{
  "type": "tun",
  "address": ["10.20.0.1/30"],
  "auto_route": true,
  "loopback_address": ["10.7.0.1"],
  "stack": "gvisor"
}
```

## PlaceDrift 0.2.1 Build 8

Build 8 changes the transport indicator from a TCP-only probe to a **RemotePairing protocol-level probe**.

The health check now does this:

```text
Discover `_remotepairing._tcp`
  → connect to `10.7.0.1:<dynamic RemotePairing port>`
  → send a real RPPairing `attemptPairVerify` handshake frame
  → require a valid RPPairing handshake response
  → only then show the transport as connected
```

This avoids the false green state seen with Loon and Surge, where a userspace TUN stack may report a TCP socket as ready even though packets are not actually reflected back to the iPhone RemotePairing service.

Build 8 also includes:

- Karing in the confirmed-compatible list;
- Apple Maps, Amap / 高德地图, and Baidu Maps / 百度地图 share parsing;
- map-share coordinate updates in the main UI;
- saved-pairing protection so **Start Pairing** is hidden after a valid pairing record exists;
- first-launch location permission requests and background keep-alive support;
- App Shortcuts for a Location object, latitude/longitude, and Restore Real Location;
- an original generated PlaceDrift app icon (map pin + motion trails), produced during CI so all required iPhone/iPad icon sizes are packaged in the IPA.

## Map sharing

1. Pair PlaceDrift with the iPhone.
2. Leave **Enable Maps sharing** on.
3. Grant PlaceDrift **Always** location access when requested. iOS controls when the upgrade prompt appears, so the second prompt may be deferred.
4. Keep a compatible TUN/proxy app connected with the required `10.7.0.1` self-loop enabled.
5. In a supported map app, choose a place and use **Share → PlaceDrift**.

Supported parser paths:

- **Apple Maps** — direct coordinate URLs and expanded Apple Maps share links.
- **Amap / 高德地图** — common `p=`, `q=`, `lnglat=`, and `position=` forms, including expanded short links. GCJ-02 is converted to WGS-84 before LocationSimulation.
- **Baidu Maps / 百度地图** — direct `location=` / `latlng=` forms, BD09MC `@x,y` map URLs, and page payloads exposing BD09MC `x/y` values. BD-09 / BD09MC is converted to WGS-84 before LocationSimulation.

Some Baidu short links may only expose POI coordinates after page-script execution. Those cases may need a later WebKit fallback.

The embedded `PlaceDriftShare.appex` extracts coordinates from shared map content and forwards them over a loopback-only bridge to the running PlaceDrift session.

If PlaceDrift has been force-quit, reopen it before using the share extension so the local receiver and background session can start again.

## Shortcuts

PlaceDrift exposes App Intents for:

- **Set PlaceDrift Location** — pass a Shortcuts `Location` directly;
- **Set PlaceDrift Coordinates** — pass latitude and longitude as numbers;
- **Restore Real Location**.

## URL scheme

```text
placedrift://set?lat=34.052235&lon=-118.243683
placedrift://clear
placedrift://pair
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

The build script also generates the complete app-icon PNG set from `scripts/generate-app-icon.swift` before Xcode builds the target.

The unsigned IPA contains the embedded `PlaceDriftShare.appex`. The main app and extension must both remain signed as part of the same installed bundle.

For the current LCSugn test workflow, if an updated build will not overwrite the installed app, enabling **Remove Embedded** before re-signing has been confirmed to allow the update while keeping the same bundle identifier.

## Privacy

Pairing records and CoreDevice credentials remain on-device and are stored in Keychain. Do not upload pairing records, AltIRK material, or private device credentials to GitHub, web pages, or analytics services.
