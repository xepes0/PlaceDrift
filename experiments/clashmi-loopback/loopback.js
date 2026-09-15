// Clash Mi 1.0.28.1406: custom overwrite, type "js".
// No network/native APIs. Only transforms the supplied configuration.
function main(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("Expected a Clash configuration object");
  }
  if (config.tun != null &&
      (typeof config.tun !== "object" || Array.isArray(config.tun))) {
    throw new Error("tun must be a mapping");
  }
  var tun = config.tun || {};
  var addresses = tun["loopback-address"];
  if (addresses != null && (!Array.isArray(addresses) ||
      addresses.some(function (address) { return typeof address !== "string"; }))) {
    throw new Error("tun.loopback-address must be a list of address strings");
  }
  addresses = (addresses || []).slice();
  if (addresses.indexOf("10.7.0.1") === -1) addresses.push("10.7.0.1");
  tun.enable = true;
  tun.stack = "system";
  tun["auto-route"] = true;
  tun["auto-detect-interface"] = true;
  tun["loopback-address"] = addresses;
  config.tun = tun;
  return config;
}
