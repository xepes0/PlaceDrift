// WLOC RemotePairing TCP connect diagnostic.
// Runs in Safari via Shortcuts on a plain HTTP page. It does not read pairing data.
// It compares the discovered RemotePairing TCP port against a deliberately closed control port.

const WLOC_TCP_PROBE_ID = "wloc-tcp-connect-probe-overlay";
const WLOC_TCP_PROBE_WS = "ws://127.0.0.1:17890/wloc";
const WLOC_TCP_PROBE_UUID = "b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a";

(() => {
  document.getElementById(WLOC_TCP_PROBE_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_TCP_PROBE_ID;
  overlay.style.cssText = [
    "position:fixed","z-index:2147483647","left:12px","right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)","max-height:calc(100vh - 24px)",
    "overflow:auto","background:#fff","color:#111","border:1px solid #bbb",
    "border-radius:16px","box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px","font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC RemotePairing TCP Probe</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:12px">
      Safari → Clash Mi VLESS/WebSocket → TCP connect only. No pairing record, no Pair Verify payload.
    </div>
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">iPhone Wi-Fi IPv4</label>
    <input id="wloc-tcp-host" value="192.168.10.40" autocapitalize="off" autocomplete="off"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:10px">
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">RemotePairing port</label>
    <input id="wloc-tcp-port" inputmode="numeric" value="49152"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:10px">
    <button id="wloc-tcp-service" style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;margin-bottom:8px">Test RemotePairing port</button>
    <button id="wloc-tcp-control" style="width:100%;font-size:17px;padding:12px;border:0;border-radius:10px;background:#e9e9ee;color:#111;margin-bottom:8px">Test closed control port 1</button>
    <button id="wloc-tcp-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-bottom:8px">关闭</button>
    <pre id="wloc-tcp-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:12px 0 0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:150px">等待测试…</pre>
  `;
  document.documentElement.appendChild(overlay);

  const hostInput = overlay.querySelector("#wloc-tcp-host");
  const portInput = overlay.querySelector("#wloc-tcp-port");
  const serviceButton = overlay.querySelector("#wloc-tcp-service");
  const controlButton = overlay.querySelector("#wloc-tcp-control");
  const closeButton = overlay.querySelector("#wloc-tcp-close");
  const logBox = overlay.querySelector("#wloc-tcp-log");

  const UUID_BYTES = (() => {
    const hex = WLOC_TCP_PROBE_UUID.replaceAll("-", "");
    const out = new Uint8Array(16);
    for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return out;
  })();

  const log = (m) => {
    const ts = new Date().toLocaleTimeString();
    logBox.textContent += `[${ts}] ${m}\n`;
    logBox.scrollTop = logBox.scrollHeight;
  };

  const ipv4 = (host) => {
    const p = host.trim().split(".").map(Number);
    if (p.length !== 4 || p.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) {
      throw new Error("IPv4 格式不正确");
    }
    return new Uint8Array(p);
  };

  const concat = (...parts) => {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let off = 0;
    for (const p of parts) { out.set(p, off); off += p.length; }
    return out;
  };

  function vlessTcpRequest(host, port) {
    const ip = ipv4(host);
    const h = new Uint8Array(22);
    let o = 0;
    h[o++] = 0x00;               // VLESS version
    h.set(UUID_BYTES, o); o += 16;
    h[o++] = 0x00;               // addon length
    h[o++] = 0x01;               // TCP
    h[o++] = (port >> 8) & 0xff;
    h[o++] = port & 0xff;
    h[o++] = 0x01;               // IPv4
    return concat(h, ip);
  }

  async function runProbe(host, port, label) {
    serviceButton.disabled = true;
    controlButton.disabled = true;
    hostInput.disabled = true;
    portInput.disabled = true;
    logBox.textContent = "";

    let ws;
    let openedAt = 0;
    let sentAt = 0;
    let firstRxAt = 0;
    let settled = false;

    const finish = (reason) => {
      if (settled) return;
      settled = true;
      const now = performance.now();
      const aliveMs = sentAt ? Math.round(now - sentAt) : 0;
      log(`RESULT ${reason}; aliveAfterVlessSend=${aliveMs}ms`);
      try { ws?.close(); } catch (_) {}
      serviceButton.disabled = false;
      controlButton.disabled = false;
      hostInput.disabled = false;
      portInput.disabled = false;
    };

    try {
      log(`${label}`);
      log(`Target ${host}:${port}`);
      log(`Opening ${WLOC_TCP_PROBE_WS}`);
      ws = new WebSocket(WLOC_TCP_PROBE_WS);
      ws.binaryType = "arraybuffer";

      ws.onopen = () => {
        openedAt = performance.now();
        log("WebSocket OPEN");
        ws.send(vlessTcpRequest(host, port));
        sentAt = performance.now();
        log("VLESS TCP connect request sent (zero TCP payload)");
      };

      ws.onmessage = (event) => {
        if (!firstRxAt) firstRxAt = performance.now();
        const b = new Uint8Array(event.data);
        const delay = sentAt ? Math.round(firstRxAt - sentAt) : 0;
        log(`RX ${b.length} bytes after ${delay}ms: ${Array.from(b.slice(0, 16)).map(x => x.toString(16).padStart(2, "0")).join(" ")}`);
        if (b.length >= 2 && b[0] === 0x00) {
          log(`VLESS response header observed; addonLen=${b[1]}`);
        }
      };

      ws.onerror = () => {
        const now = performance.now();
        const age = sentAt ? Math.round(now - sentAt) : (openedAt ? Math.round(now - openedAt) : 0);
        log(`WebSocket ERROR after ${age}ms`);
      };

      ws.onclose = (event) => {
        const now = performance.now();
        const age = sentAt ? Math.round(now - sentAt) : (openedAt ? Math.round(now - openedAt) : 0);
        log(`WebSocket CLOSED code=${event.code} reason=${event.reason || "<empty>"} after ${age}ms`);
        if (!settled) finish(`CLOSED_${event.code}`);
      };

      setTimeout(() => {
        if (settled) return;
        if (ws.readyState === WebSocket.OPEN) {
          log("STILL OPEN after 8s with zero TCP payload");
          finish("STILL_OPEN_8S");
        } else {
          finish(`STATE_${ws.readyState}_AT_8S`);
        }
      }, 8000);
    } catch (error) {
      log(`EXCEPTION ${error?.message || String(error)}`);
      finish("EXCEPTION");
    }
  }

  serviceButton.onclick = () => {
    const host = hostInput.value.trim();
    const port = Number.parseInt(portInput.value, 10);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      logBox.textContent = "ERROR: port 必须是 1-65535";
      return;
    }
    runProbe(host, port, "SERVICE PROBE");
  };

  controlButton.onclick = () => {
    const host = hostInput.value.trim();
    runProbe(host, 1, "CONTROL PROBE (expected closed)");
  };

  closeButton.onclick = () => overlay.remove();
})();
