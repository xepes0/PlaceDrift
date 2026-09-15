// Clash Mi 1.0.28.1406 profile patch / JS override.
// Purpose: keep the validated 10.7.0.1 loopback and expose a localhost-only
// VLESS-over-WebSocket listener for Safari transport experiments.
//
// This script only mutates Mihomo configuration. It does not read pairing
// records and does not implement CoreDevice itself.

const WLOC_BRIDGE_NAME = "wloc-browser-bridge";
const WLOC_BRIDGE_UUID = "b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a";
const WLOC_BRIDGE_PORT = 17890;

function main(config) {
  config = config || {};

  const tun = config.tun || {};
  tun.enable = true;
  tun.stack = "mixed";
  tun["auto-route"] = true;
  tun["auto-detect-interface"] = true;

  const loopback = Array.isArray(tun["loopback-address"])
    ? tun["loopback-address"].slice()
    : [];
  if (!loopback.includes("10.7.0.1")) {
    loopback.push("10.7.0.1");
  }
  tun["loopback-address"] = loopback;
  config.tun = tun;

  const listeners = Array.isArray(config.listeners)
    ? config.listeners.filter((item) => !item || item.name !== WLOC_BRIDGE_NAME)
    : [];

  listeners.push({
    name: WLOC_BRIDGE_NAME,
    type: "vless",
    listen: "127.0.0.1",
    port: WLOC_BRIDGE_PORT,
    users: [
      {
        username: "wloc-browser",
        uuid: WLOC_BRIDGE_UUID,
      },
    ],
    "ws-path": "/wloc",
    "allow-insecure": true,
  });

  config.listeners = listeners;
  return config;
}
