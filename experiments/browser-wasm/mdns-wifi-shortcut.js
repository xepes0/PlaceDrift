// WLOC RemotePairing mDNS probe via the iPhone Wi-Fi IPv4 address.
// Inject into a plain HTTP page from Shortcuts (for example http://neverssl.com).
// This does not read or upload a pairing record.

const WLOC_MDNS_WIFI_OVERLAY_ID = "wloc-mdns-wifi-overlay";
const WLOC_MDNS_WIFI_WS_URL = "ws://127.0.0.1:17890/wloc";
const WLOC_MDNS_WIFI_UUID = "b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a";

(() => {
  document.getElementById(WLOC_MDNS_WIFI_OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_MDNS_WIFI_OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed","z-index:2147483647","left:12px","right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)","max-height:calc(100vh - 24px)",
    "overflow:auto","background:#fff","color:#111","border:1px solid #bbb",
    "border-radius:16px","box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px","font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC RemotePairing Wi-Fi Discovery</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:12px">
      Safari → Clash Mi VLESS/WebSocket → UDP → iPhone Wi-Fi IP:5353
    </div>
    <input id="wloc-mdns-wifi-ip" value="192.168.10.68" inputmode="decimal" autocapitalize="off" autocomplete="off"
      style="width:100%;box-sizing:border-box;font-size:17px;padding:12px;border:1px solid #ccc;border-radius:10px;margin-bottom:8px" />
    <button id="wloc-mdns-wifi-run" style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;margin-bottom:8px">Query this Wi-Fi IP:5353</button>
    <button id="wloc-mdns-wifi-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-bottom:8px">关闭</button>
    <pre id="wloc-mdns-wifi-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:160px">Ready.</pre>
  `;
  document.documentElement.appendChild(overlay);

  const ipInput = overlay.querySelector("#wloc-mdns-wifi-ip");
  const runButton = overlay.querySelector("#wloc-mdns-wifi-run");
  const closeButton = overlay.querySelector("#wloc-mdns-wifi-close");
  const logBox = overlay.querySelector("#wloc-mdns-wifi-log");
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  const log = (msg) => {
    logBox.textContent += `\n[${new Date().toLocaleTimeString()}] ${msg}`;
    logBox.scrollTop = logBox.scrollHeight;
  };

  function concat(...parts) {
    const n = parts.reduce((s, p) => s + p.length, 0);
    const out = new Uint8Array(n);
    let o = 0;
    for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  }

  function uuidBytes(uuid) {
    const hex = uuid.replaceAll("-", "");
    const out = new Uint8Array(16);
    if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new Error("Invalid UUID");
    for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return out;
  }

  function ipv4(host) {
    const xs = host.split(".").map(Number);
    if (xs.length !== 4 || xs.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) {
      throw new Error("Invalid IPv4 address");
    }
    return new Uint8Array(xs);
  }

  function dnsName(name) {
    const out = [];
    for (const part of name.replace(/\.$/, "").split(".")) {
      const b = enc.encode(part);
      out.push(b.length, ...b);
    }
    out.push(0);
    return new Uint8Array(out);
  }

  function mdnsQuery() {
    const h = new Uint8Array(12);
    h[5] = 1; // QDCOUNT=1
    // PTR + IN + QU bit: ask mDNSResponder to send a unicast reply.
    return concat(h, dnsName("_remotepairing._tcp.local"), new Uint8Array([0x00,0x0c,0x80,0x01]));
  }

  function vlessUDP(host, port, datagram) {
    const head = new Uint8Array(26);
    let o = 0;
    head[o++] = 0;
    head.set(uuidBytes(WLOC_MDNS_WIFI_UUID), o); o += 16;
    head[o++] = 0;
    head[o++] = 2; // UDP
    head[o++] = (port >> 8) & 0xff;
    head[o++] = port & 0xff;
    head[o++] = 1; // IPv4
    head.set(ipv4(host), o);
    const frame = new Uint8Array(2 + datagram.length);
    frame[0] = (datagram.length >> 8) & 0xff;
    frame[1] = datagram.length & 0xff;
    frame.set(datagram, 2);
    return concat(head, frame);
  }

  const u16 = (b, o) => (b[o] << 8) | b[o + 1];

  function readName(bytes, start) {
    const labels = [];
    let offset = start, next = start, jumped = false;
    const seen = new Set();
    for (let guard = 0; guard < 128; guard++) {
      if (offset >= bytes.length) throw new Error("DNS name out of range");
      const len = bytes[offset];
      if ((len & 0xc0) === 0xc0) {
        if (offset + 1 >= bytes.length) throw new Error("DNS pointer truncated");
        const ptr = ((len & 0x3f) << 8) | bytes[offset + 1];
        if (!jumped) next = offset + 2;
        if (seen.has(ptr)) throw new Error("DNS pointer loop");
        seen.add(ptr); offset = ptr; jumped = true; continue;
      }
      if (len === 0) {
        if (!jumped) next = offset + 1;
        return { name: labels.join("."), next };
      }
      if (len > 63 || offset + 1 + len > bytes.length) throw new Error("Bad DNS label");
      labels.push(dec.decode(bytes.slice(offset + 1, offset + 1 + len)));
      offset += 1 + len;
      if (!jumped) next = offset;
    }
    throw new Error("DNS name too deep");
  }

  function parseTXT(bytes, start, end) {
    const out = [];
    let o = start;
    while (o < end) {
      const len = bytes[o++];
      if (o + len > end) break;
      out.push(dec.decode(bytes.slice(o, o + len)));
      o += len;
    }
    return out;
  }

  function parseDNS(bytes) {
    if (bytes.length < 12) throw new Error("DNS packet too short");
    const qd = u16(bytes,4), an = u16(bytes,6), ns = u16(bytes,8), ar = u16(bytes,10);
    let o = 12;
    for (let i = 0; i < qd; i++) { const q = readName(bytes,o); o = q.next + 4; }
    const records = [];
    for (let i = 0; i < an + ns + ar; i++) {
      const owner = readName(bytes,o); o = owner.next;
      if (o + 10 > bytes.length) throw new Error("Record header truncated");
      const type = u16(bytes,o), rdlen = u16(bytes,o+8);
      const rstart = o + 10, rend = rstart + rdlen;
      if (rend > bytes.length) throw new Error("Record data truncated");
      const r = { name: owner.name, type };
      if (type === 12) r.ptr = readName(bytes,rstart).name;
      if (type === 33 && rdlen >= 6) { r.port = u16(bytes,rstart+4); r.target = readName(bytes,rstart+6).name; }
      if (type === 16) r.txt = parseTXT(bytes,rstart,rend);
      records.push(r); o = rend;
    }
    return records;
  }

  function run() {
    const target = ipInput.value.trim();
    try { ipv4(target); } catch (e) { logBox.textContent = `ERROR: ${e.message}`; return; }
    logBox.textContent = `Target ${target}:5353`;
    runButton.disabled = true;
    let firstResponse = true;
    let stream = new Uint8Array(0);
    let gotDatagram = false;
    let ws;
    const finish = () => { runButton.disabled = false; };
    const timer = setTimeout(() => {
      if (!gotDatagram) log("TIMEOUT: no UDP mDNS datagram in 8s");
      try { ws?.close(); } catch (_) {}
      finish();
    }, 8000);

    try {
      ws = new WebSocket(WLOC_MDNS_WIFI_WS_URL);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        log("WebSocket OPEN");
        const query = mdnsQuery();
        ws.send(vlessUDP(target, 5353, query));
        log(`Sent PTR query (${query.length} bytes)`);
      };
      ws.onmessage = (event) => {
        let chunk = new Uint8Array(event.data);
        if (firstResponse) {
          stream = concat(stream, chunk);
          if (stream.length < 2) return;
          const headerLength = 2 + stream[1];
          if (stream.length < headerLength) return;
          if (stream[0] !== 0) { log(`Unexpected VLESS version=${stream[0]}`); ws.close(); return; }
          log(`VLESS response header OK addons=${stream[1]}`);
          chunk = stream.slice(headerLength);
          stream = new Uint8Array(0);
          firstResponse = false;
        }
        stream = concat(stream, chunk);
        while (stream.length >= 2) {
          const len = u16(stream,0);
          if (stream.length < 2 + len) break;
          const datagram = stream.slice(2,2+len);
          stream = stream.slice(2+len);
          gotDatagram = true;
          log(`UDP datagram ${datagram.length} bytes`);
          try {
            const records = parseDNS(datagram);
            for (const r of records) {
              if (r.ptr) log(`PTR ${r.name} -> ${r.ptr}`);
              if (r.port) log(`SRV ${r.name} port=${r.port} target=${r.target}`);
              if (r.txt) log(`TXT ${r.name} ${r.txt.join(" | ")}`);
            }
            const srv = records.find((r) => r.type === 33 && r.port);
            if (srv) log(`REMOTEPAIRING_PORT=${srv.port}`);
          } catch (e) { log(`DNS parse error: ${e?.message || e}`); }
        }
      };
      ws.onerror = () => log("WebSocket ERROR");
      ws.onclose = (event) => {
        clearTimeout(timer);
        log(`WebSocket CLOSED code=${event.code} reason=${event.reason || "<empty>"}`);
        finish();
      };
    } catch (e) {
      clearTimeout(timer);
      log(`EXCEPTION: ${e?.message || e}`);
      finish();
    }
  }

  runButton.onclick = run;
  closeButton.onclick = () => overlay.remove();
})();
