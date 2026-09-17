# PlaceDrift architecture

## Product boundary

PlaceDrift is a native CoreDevice location-control app. The current public-beta product path does not depend on browser/MITM experiments, WLOC Worker parsing, Shortcuts/App Intents, GeoServices region switching, or an embedded VPN.

```text
Apple Maps / Amap / Baidu Maps
        │
        ▼
Share Extension
        │
        ├─ local URL / page parsing
        ├─ GCJ-02 → WGS-84
        └─ BD-09 / BD09MC → WGS-84
        │
        ▼
loopback-only Share Bridge
        │
        ▼
CoreDeviceController
        │
        ├─ Bonjour pairing host
        ├─ Keychain pairing record
        ├─ RemotePairing discovery
        └─ background location keep-alive
        │
        ▼
Rust CoreDevice engine
        │
        ▼
10.7.0.1 through a compatible TUN self-loop
        │
        ▼
RemotePairing → Pair Verify → TLS-PSK → RSD → DVT → LocationSimulation
```

## TUN boundary

PlaceDrift intentionally does not ship a Network Extension and does not start or control a VPN. A separate compatible TUN app must provide the `10.7.0.1` self-device loopback transport.

Physical-device testing has confirmed the current path with LocalDevVPN, Clash Mi, Clash, and Karing. Tested Loon, Surge, and Shadowrocket configurations do not currently pass the RemotePairing protocol-level health check.

## User workflow

The supported public-beta workflow is intentionally small:

```text
Choose a place in Apple Maps / Amap / Baidu Maps
→ Share
→ PlaceDrift
→ local coordinate parsing
→ update or start LocationSimulation
```

The main app also keeps manual latitude/longitude entry and the basic `placedrift://` deep-link scheme for diagnostics and direct control.
