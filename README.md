# WLOC CoreDevice Lab

Experimental iOS 17+/iOS 27 research project for system location simulation without USB and without modifying the legacy WLOC MITM flow.

## Goals

- Keep `xepes0/wloc` untouched.
- Use an on-device network tunnel path instead of `gs-loc.apple.com` MITM.
- Explore Clash Mi / Mihomo as the always-on VPN host.
- Reach the iPhone's own RemotePairing/CoreDevice services through an on-device loopback path.
- Drive `RemotePairing -> TLS-PSK -> RSD -> DVT -> LocationSimulation` from a native bridge.
- Keep pairing material on-device only.

## Target architecture

```text
WLOC web / Shortcut
        |
        v
Custom URL / local command
        |
        v
Clash Mi host integration
  |                |
  |                +--> normal Mihomo proxy traffic
  |
  +--> local-device loopback (10.7.0.1)
                |
                v
          RemotePairing
                |
             TLS-PSK
                |
               RSD
                |
               DVT
                |
      LocationSimulation
```

## Current phase

### Ready-to-import Clash Mi loopback PoC

Start with the [Clash Mi 1.0.28.1406 import and device test guide](experiments/clashmi-loopback/README.md): minimal YAML overwrite, `main(config)` JavaScript overwrite, standalone direct-only profile, and offline validation/CI. Physical-device loopback support remains unverified.

1. Prove the `10.7.0.1` self-device loopback behavior independently.
2. Keep the CoreDevice engine isolated from any proxy UI/framework.
3. Only after both pieces work, integrate them with Clash Mi.

## Safety / privacy boundary

Pairing records, AltIRK values, TLS material, device identifiers and native diagnostics must never be sent to a Worker, web page, analytics service or GitHub.

## Status

Experimental. Not yet validated on a physical iOS 27 device.
