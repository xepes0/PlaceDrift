# Clash Mi integration plan

## Decision

A Clash Mi JavaScript override / YAML module is not sufficient for the local-device transport.

The required behavior is below the rule/config layer: traffic addressed to the synthetic peer (default `10.7.0.1`) must be reflected back into the iPhone as if it arrived from that peer. LocalDevVPN achieves this at the packet-tunnel layer by swapping the IPv4 source and destination addresses and reinjecting the packet.

For Clash Mi, the integration therefore belongs in one of these layers:

1. **Preferred PoC:** a packet shim immediately before Mihomo consumes the iOS TUN stream.
2. **Alternative:** a dedicated local-device loopback feature in the Libclash/Mihomo TUN dispatcher.

It should not be implemented as a proxy rule, HTTP rewrite, JS override or fake DIRECT route.

## Traffic split

```text
NEPacketTunnel
    |
    +-- dst == 10.7.0.1 --> local-device reflector --> reinject to iOS
    |
    +-- everything else --> Mihomo unchanged
```

The reflector must fail closed. It must never rewrite unrelated IPv4 traffic and must never attempt to reinterpret IPv6 as IPv4.

## Why a second packetFlow reader is unsafe

Clash Mi already hands the TUN file descriptor to Libclash. Adding an independent `packetFlow.readPackets()` loop in the extension would create two consumers for the same virtual interface and can race/steal packets from Mihomo. The integration point must be singular: one dispatcher decides whether a packet is local-device traffic or normal proxy traffic.

## CoreDevice path

Once self-device networking works, the native engine will use:

```text
RemotePairing
  -> pair verify
  -> secure tunnel listener
  -> TLS-PSK tunnel
  -> RSD
  -> DVT RemoteServer
  -> LocationSimulation
```

Pairing material stays in the iPhone Keychain. Web callbacks receive only fixed status codes.

## Integration policy

Clash Mi is GPL-3.0. This repository currently keeps the reusable packet algorithm and CoreDevice protocol work independent. If/when Clash Mi source is copied or modified here, that integration subtree must remain GPL-compatible and retain upstream notices.

## Milestones

- [x] Pure Swift selective IPv4 reflector with tests.
- [ ] Confirm packet checksum invariants with TCP and UDP fixtures.
- [ ] Add a Clash Mi adapter prototype against a pinned upstream commit.
- [ ] Validate `10.7.0.1` reachability on a physical iPhone.
- [ ] Add CoreDevice native engine.
- [ ] Validate RemotePairing service discovery through the reflector.
- [ ] Validate DVT `LocationSimulation.set/clear` on iOS 27.
- [ ] Add web/deep-link control only after the native path is stable.
