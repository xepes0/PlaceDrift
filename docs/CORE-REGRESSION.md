# Clash Mi / Mihomo loopback regression matrix

This document tracks the narrow transport capability needed by the project: an iPhone process must be able to reach the iPhone's own RemotePairing service through a synthetic peer address such as `10.7.0.1`.

## Version boundary

| Clash Mi | Mihomo core | sing-tun | Observed / expected status |
| --- | --- | --- | --- |
| 1.0.28.1406 | 1.19.29 | 0.4.21 | Historical known-good baseline for LocalDevVPN replacement |
| 1.0.29.1500 | 1.19.30 | 0.4.22 | First suspicious boundary after core update |
| 1.0.30.1603 | 1.19.31 | 0.4.24 | Current test target; not yet physically verified |

The 1.19.29 -> 1.19.30 Mihomo compare does not show a direct TUN implementation rewrite in the Mihomo repository. The more relevant dependency changes are:

- `sing-tun 0.4.21 -> 0.4.22`
- a large gVisor revision jump
- introduction of `mipstack`

The `sing-tun 0.4.21 -> 0.4.22` range is especially suspicious on Apple platforms because it changes `internal/fdbased_darwin/endpoint.go` and `internal/fdbased_darwin/processors.go` and updates gVisor.

This is a hypothesis, not yet a proven root cause. Do not patch Clash Mi until the physical-device matrix below is completed.

## Physical-device matrix

Use the same iPhone, same iOS build and same minimal profile for every row.

| Clash Mi build | stack | `loopback-address` | Result |
| --- | --- | --- | --- |
| 1.0.28.1406 | system | 10.7.0.1 | pending/reconfirm |
| 1.0.28.1406 | gvisor | 10.7.0.1 | pending |
| 1.0.28.1406 | mixed | 10.7.0.1 | pending |
| 1.0.30.1603 | system | 10.7.0.1 | pending |
| 1.0.30.1603 | gvisor | 10.7.0.1 | pending |
| 1.0.30.1603 | mixed | 10.7.0.1 | pending |

## What counts as success

A successful test must prove **self-device TCP**, not merely that the VPN starts or the address appears in a route table.

For an already paired device, the strongest later probe will be:

```text
10.7.0.1:<resolved _remotepairing._tcp port>
```

followed by cryptographic validation of the service `identifier/authTag` against the saved pairing record. Until the CoreDevice probe UI exists, an existing app that already depends on LocalDevVPN-style loopback can be used only as a coarse transport smoke test.

## Decision tree

1. If current 1.0.30.1603 works on at least one stack, do not patch Clash Mi. Standardize on that stack.
2. If 1.0.28.1406 works and 1.0.30.1603 fails on all stacks, reproduce with Mihomo 1.19.29 vs 1.19.31.
3. If the failure follows `sing-tun`, test a current Mihomo build with the known-good TUN dependency or the smallest compatible backport.
4. Only if upstream `loopback-address` cannot be restored reliably, use the independent `LoopbackCore` implementation as the oracle for a native packet shim.

## Why this order matters

`loopback-address` is already a first-class Mihomo TUN concept and has historically been used by iOS users as a LocalDevVPN substitute. Reimplementing the packet path inside Clash Mi before isolating the regression would create a larger fork and a much harder maintenance burden.
