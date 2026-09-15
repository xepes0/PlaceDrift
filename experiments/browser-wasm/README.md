# Browser/WASM transport experiment

Goal: keep the original Clash Mi app and avoid a permanent extra CoreDevice IPA.

## Phase A: Safari -> Clash Mi -> raw TCP

Clash Mi 1.0.28.1406 supports JS profile patches through `main(config)`. Import `clashmi-wloc-bridge.js` as a JS profile patch and activate it. It preserves existing listeners, forces the already-tested TUN baseline, keeps `10.7.0.1` in `loopback-address`, and adds this localhost-only inbound:

```yaml
listeners:
  - name: wloc-browser-bridge
    type: vless
    listen: 127.0.0.1
    port: 17890
    users:
      - username: wloc-browser
        uuid: b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a
    ws-path: /wloc
    allow-insecure: true
```

The public `transport-test.html` page contains no pairing credential support. It implements only enough VLESS to open a TCP stream and defaults to `example.com:80`.

Expected success log:

```text
WebSocket OPEN
Sending VLESS TCP request ...
VLESS response header OK
TCP DATA:
HTTP/...
```

Possible first blocker on iOS Safari: an HTTPS page may reject `ws://127.0.0.1`. If that happens, do not weaken Safari security globally. The next experiment is a local `wss://` listener with a narrowly-scoped trusted certificate/profile.

## Pairing record export

The Browser/WASM branch also adds `Export pairing record for Browser PoC` to the temporary native Probe. Export is done through the system file exporter. The record must remain local to the device. Never upload it to GitHub, Cloudflare, chat, analytics, or a public web server.

A later browser page will import this record with `<input type=file>` and retain it only in local browser storage.

## Phase B after Phase A succeeds

1. Add VLESS UDP framing.
2. Query `_remotepairing._tcp.local` through mDNS, preferring a unicast query through `10.7.0.1:5353`.
3. Validate returned `identifier`/`authTag` against the pairing record.
4. Compile `idevice` with its `wasm` feature and provide a WebSocket-backed `ReadWrite` transport.
5. Reconnect Pair Verify -> TLS-PSK -> RSD -> DVT -> LocationSimulation in WASM.

The legacy `xepes0/wloc` repository is not used or modified by this experiment.
