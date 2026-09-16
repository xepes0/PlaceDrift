// WLOC RemotePairing mDNS discovery probe for Safari Shortcuts.
// Inject this into a plain HTTP page (e.g. http://neverssl.com).
// No pairing record is read or uploaded.

const WLOC_MDNS_OVERLAY_ID = "wloc-mdns-overlay";
const WLOC_MDNS_WS_URL = "ws://127.0.0.1:17890/wloc";
const WLOC_MDNS_UUID = "b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a";

(() => {
  document.getElementById(WLOC_MDNS_OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_MDNS_OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed",
    "z-index:2147483647",
    "left:12px",
    "right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)",
    "max-height:calc(100vh - 24px)",
    "overflow:auto",
    "background:#fff",
    "color:#111",
    "border:1px solid #bbb",
    "border-radius:16px",
    "box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px",
    "font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC RemotePairing Discovery</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:12px">
      Safari → Clash Mi VLESS/WebSocket → UDP mDNS → _remotepairing._tcp.local
    </div>
    <button id="wloc-mdns-mcast" style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;margin-bottom:8px">Discover via 224.0.0.251</button>
    <button id="wloc-mdns-peer" style="width:100%;font-size:16px;padding:12px;border:0;border-radius:10px;background:#e9e9ee;color:#111;margin-bottom:8px">Try 10.7.0.1:5353</button>
    <button id="wloc-mdns-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-bottom:8px">关闭</button>
    <pre id="wloc-mdns-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:140px">Ready.</pre>
  `;
  document.documentElement.appendChild(overlay);

  const logBox = overlay.querySelector("#wloc-mdns-log");
  const mcastButton = overlay.querySelector("#wloc-mdns-mcast");
  const peerButton = overlay.querySelector("#wloc-mdns-peer");
  const closeButton = overlay.querySelector("#wloc-mdns-close");
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  const log = (msg) => {
    const prefix = new Date().toLocaleTimeString();
    logBox.textContent += `\n[${prefix}] ${msg}`;
    logBox.scrollTop = logBox.scrollHeight;
  };

  function concat(...parts) {
    const size = parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(size);
    let offset = 0;
    for (const p of parts) {
      out.set(p, offset);
      offset += p.length;
    }
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
      throw new Error("IPv4 destination required");
    }
    return new Uint8Array(xs);
  }

  function vlessUDPRequest(host, port, datagram) {
    const head = new Uint8Array(26);
    let o = 0;
    head[o++] = 0;
    head.set(uuidBytes(WLOC_MDNS_UUID), o); o += 16;
    head[o++] = 0;
    head[o++] = 2;
    head[o++] = (port >> 8) & 0xff;
    head[o++] = port & 0xff;
    head[o++] = 1;
    head.set(ipv4(host), o);

    const framed = new Uint8Array(2 + datagram.length);
    framed[0] = (datagram.length >> 8) & 0xff;
    framed[1] = datagram.length & 0xff;
    framed.set(datagram, 2);
    return concat(head, framed);
  }

  function dnsName(name) {
    const bytes = [];
    for (const part of name.replace(/\.$/, "").split(".")) {
      const value = encoder.encode(part);
      bytes.push(value.length, ...value);
    }
    bytes.push(0);
    return new Uint8Array(bytes);
  }

  function mdnsPtrQuery() {
    const header = new Uint8Array(12);
    header[5] = 1; // QDCOUNT=1
    const qname = dnsName("_remotepairing._tcp.local");
    // PTR, class IN with QU bit so responder may unicast the response.
    return concat(header, qname, new Uint8Array([0x00, 0x0c, 0x80, 0x01]));
  }

  const u16 = (b, o) => (b[o] << 8) | b[o + 1];

  function readName(bytes, start) {
    const labels = [];
    let offset = start;
    let next = start;
    let jumped = false;
    const visited = new Set();
    for (let guard = 0; guard < 128; guard++) {
      if (offset >= bytes.length) throw new Error("DNS name out of range");
      const len = bytes[offset];
      if ((len & 0xc0) === 0xc0) {
        if (offset + 1 >= bytes.length) throw new Error("DNS pointer truncated");
        const pointer = ((len & 0x3f) << 8) | bytes[offset + 1];
        if (!jumped) next = offset + 2;
        if (visited.has(pointer)) throw new Error("DNS pointer loop");
        visited.add(pointer);
        offset = pointer;
        jumped = true;
        continue;
      }
      if (len === 0) {
        if (!jumped) next = offset + 1;
        return { name: labels.join("."), next };
      }
      if (len > 63 || offset + 1 + len > bytes.length) throw new Error("Bad DNS label");
      labels.push(decoder.decode(bytes.slice(offset + 1, offset + 1 + len)));
      offset += 1 + len;
      if (!jumped) next = offset;
    }
    throw new Error("DNS name too deep");
  }

  function parseTXT(bytes, start, end) {
    const values = [];
    let o = start;
    while (o < end) {
      const len = bytes[o++];
      if (o + len > end) break;
      values.push(decoder.decode(bytes.slice(o, o + len)));
      o += len;
    }
    return values;
  }

  function parseDNS(bytes) {
    if (bytes.length < 12) throw new Error("DNS packet too short");
    const qd = u16(bytes, 4), an = u16(bytes, 6), ns = u16(bytes, 8), ar = u16(bytes, 10);
    let o = 12;
    for (let i = 0; i < qd; i++) {
      const name = readName(bytes, o);
      o = name.next + 4;
    }
    const records = [];
    for (let i = 0; i < an + ns + ar; i++) {
      const owner = readName(bytes, o);
      o = owner.next;
      if (o + 10 > bytes.length) throw new Error("Record header truncated");
      const type = u16(bytes, o);
      const rdlen = u16(bytes, o + 8);
      const rstart = o + 10;
      const rend = rstart + rdlen;
      if (rend > bytes.length) throw new Error("Record data truncated");
      const rec = { name: owner.name, type };
      if (type === 12) rec.ptr = readName(bytes, rstart).name;
      if (type === 33 && rdlen >= 6) {
        rec.port = u16(bytes, rstart + 4);
        rec.target = readName(bytes, rstart + 6).name;
      }
      if (type === 16) rec.txt = parseTXT(bytes, rstart, rend);
      records.push(rec);
      o = rend;
    }
    return records;
  }

  function run(target) {
    logBox.textContent = `Target ${target}:5353`;
    mcastButton.disabled = true;
    peerButton.disabled = true;
    let firstResponse = true;
    let stream = new Uint8Array(0);
    let gotDatagram = false;
    let ws;

    const finish = () => {
      mcastButton.disabled = false;
      peerButton.disabled = false;
    };

    const timer = setTimeout(() => {
      if (!gotDatagram) log("TIMEOUT: no UDP mDNS datagram in 8s");
      try { ws?.close(); } catch (_) {}
      finish();
    }, 8000);

    try {
      ws = new WebSocket(WLOC_MDNS_WS_URL);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        log("WebSocket OPEN");
        const packet = mdnsPtrQuery();
        ws.send(vlessUDPRequest(target, 5353, packet));
        log(`Sent PTR query (${packet.length} bytes)`);
      };
      ws.onmessage = (event) => {
        let chunk = new Uint8Array(event.data);
        if (firstResponse) {
          stream = concat(stream, chunk);
          if (stream.length < 2) return;
          const headerLength = 2 + stream[1];
          if (stream.length < headerLength) return;
          if (stream[0] !== 0) {
            log(`Unexpected VLESS response version=${stream[0]}`);
            ws.close();
            return;
          }
          log(`VLESS response header OK addons=${stream[1]}`);
          chunk = stream.slice(headerLength);
          stream = new Uint8Array(0);
          firstResponse = false;
        }
        stream = concat(stream, chunk);
        while (stream.length >= 2) {
          const length = u16(stream, 0);
          if (stream.length < 2 + length) break;
          const datagram = stream.slice(2, 2 + length);
          stream = stream.slice(2 + length);
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
          } catch (error) {
            log(`DNS parse error: ${error?.message || error}`);
          }
        }
      };
      ws.onerror = () => log("WebSocket ERROR");
      ws.onclose = (event) => {
        clearTimeout(timer);
        log(`WebSocket CLOSED code=${event.code} reason=${event.reason || "<empty>"}`);
        finish();
      };
    } catch (error) {
      clearTimeout(timer);
      log(`EXCEPTION: ${error?.message || error}`);
      finish();
    }
  }

  mcastButton.onclick = () => run("224.0.0.251");
  peerButton.onclick = () => run("10.7.0.1");
  closeButton.onclick = () => overlay.remove();
})();
