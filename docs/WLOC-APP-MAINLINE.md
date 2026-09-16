# WLOC App Mainline

Branch: `wloc-app-mainline`

This branch is the new product mainline. The legacy `xepes0/wloc` repository must not be modified.

## Product decision

The browser/WASM experiments proved that Safari can reach a Clash Mi local VLESS listener and can perform useful discovery work, but Mihomo outbound sockets cannot reliably re-enter the same iPhone's RemotePairing service. The product therefore moves CoreDevice execution back into a native iOS app.

The validated native path is:

```text
WLOC App
  -> Clash Mi TUN (`loopback-address: 10.7.0.1`)
  -> RemotePairing
  -> Pair Verify
  -> TLS-PSK
  -> RSD
  -> DVT
  -> LocationSimulation
```

The existing Probe already demonstrated this path on a physical iPhone. This branch converts that proof into a small user-facing app.

## Milestones

### M0 — product shell
- Create `wloc-app/` as an independent iOS target.
- Reuse the validated CoreDevice controller/FFI without owning a VPN.
- Remove the Probe-only Network Extension entitlement.
- Add WLOC URL scheme.

### M1 — pairing and location UX
- First-run pairing wizard.
- Keychain-backed pairing record.
- Automatic `_remotepairing._tcp` discovery and identity match.
- Set, update, clear location.
- Clear error states mapped to Pair Verify / TLS-PSK / RSD / DVT / LocationSimulation.

### M2 — WLOC picker integration
- `wloc://set?lat=<lat>&lon=<lon>`.
- `wloc://clear`.
- `wloc://pair`.
- Return-to-picker flow and recent/favorite locations.

### M3 — Shortcuts / App Intents
- Set Location.
- Restore Real Location.
- Pair / connection status.

### M4 — packaging
- Stable bundle identifier and migration plan for existing pairing records.
- Unsigned IPA CI artifact.
- Signing notes for supported sideload methods.

## Current implementation note

The first product commit intentionally reuses `CoreDeviceProbeController` unchanged to avoid breaking the already validated native path. Rename/refactor happens only after the new WLOC target builds and passes a physical-device set/update/clear regression test.
