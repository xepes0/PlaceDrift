# PlaceDrift architecture

## Product boundary

PlaceDrift is independent of the earlier browser/MITM experiments. The production path is native CoreDevice.

```text
SwiftUI / App Intents
       │
       ▼
CoreDeviceController
       │
       ├─ Bonjour pairing host
       ├─ Keychain pairing record
       └─ `_remotepairing._tcp` discovery
       │
       ▼
Rust CoreDevice engine
       │
       ▼
10.7.0.1 through Clash Mi TUN loopback
       │
       ▼
RemotePairing → TLS-PSK → RSD → DVT → LocationSimulation
```

## Why Clash Mi stays separate

The app intentionally does not ship a Network Extension. This prevents it from competing with Clash Mi for the iOS VPN slot. Clash Mi provides the local self-device path; PlaceDrift performs the CoreDevice protocol.

## Shortcuts

`Set PlaceDrift Location` accepts a Shortcuts `Location` value and extracts its coordinate. This is the preferred user workflow:

```text
Get Current Location / Select Location
→ Set PlaceDrift Location
→ PlaceDrift opens
→ CoreDevice location session starts or updates
```

A second action accepts numeric latitude and longitude for automation and third-party picker workflows.
