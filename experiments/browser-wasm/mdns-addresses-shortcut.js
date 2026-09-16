// WLOC RemotePairing address probe via the iPhone Wi-Fi IPv4 mDNS responder.
// Inject into a plain HTTP page from Shortcuts (for example http://neverssl.com).
// Discovers _remotepairing._tcp.local, then queries A/AAAA for the SRV target.

const WLOC_ADDR_OVERLAY_ID = "wloc-mdns-address-overlay";
const WLOC_ADDR_WS_URL = "ws://127.0.0.1:17890/wloc";
const WLOC_ADDR_UUID = "b8842e9c-72fd-4a59-9f8d-5f3b9e9b5d2a";

(() => {
  document.getElementById(WLOC_ADDR_OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_ADDR_OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed","z-index:2147483647","left:12px","right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)","max-height:calc(100vh - 24px)",
    "overflow:auto","background:#fff","color:#111","border:1px solid #bbb",
    "border-radius:16px","box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px","font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC RemotePairing Address Probe</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:12px">
      mDNS PTR/SRV/TXT → SRV target → A + AAAA
    </div>
    <input id="wloc-addr-ip" value="192.168.10.40" inputmode="decimal" autocapitalize="off" autocomplete="off"
      style="width:100%;box-sizing:border-box;font-size:17px;padding:12px;border:1px solid #ccc;border-radius:10px;margin-bottom:8px" />
    <button id="wloc-addr-run" style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;margin-bottom:8px">Discover RemotePairing addresses</button>
    <button id="wloc-addr-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-bottom:8px">关闭</button>
    <pre id="wloc-addr-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:180px">Ready.</pre>
  `;
  document.documentElement.appendChild(overlay);

  const ipInput = overlay.querySelector("#wloc-addr-ip");
  const runButton = overlay.querySelector("#wloc-addr-run");
  const closeButton = overlay.querySelector("#wloc-addr-close");
  const logBox = overlay.querySelector("#wloc-addr-log");
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
    for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    return out;
  }

  function ipv4(host) {
    const xs = host.split(".").map(Number);
    if (xs.length !== 4 || xs.some((x) => !Number.isInteger(x) || x < 0 || x > 255)) throw new Error("Invalid IPv4 address");
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

  function dnsQuery(name, type) {
    const h = new Uint8Array(12);
    h[5] = 1;
    return concat(h, dnsName(name), new Uint8Array([(type >> 8) & 0xff, type & 0xff, 0x80, 0x01]));
  }

  function vlessUdpOpen(host, port, datagram) {
    const head = new Uint8Array(26);
    let o = 0;
    head[o++] = 0;
    head.set(uuidBytes(WLOC_ADDR_UUID), o); o += 16;
    head[o++] = 0;
    head[o++] = 2;
    head[o++] = (port >> 8) & 0xff;
    head[o++] = port & 0xff;
    head[o++] = 1;
    head.set(ipv4(host), o);
    return concat(head, udpFrame(datagram));
  }

  function udpFrame(datagram) {
    const frame = new Uint8Array(2 + datagram.length);
    frame[0] = (datagram.length >> 8) & 0xff;
    frame[1] = datagram.length & 0xff;
    frame.set(datagram, 2);
    return frame;
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

  function ipv6Text(bytes) {
    const groups = [];
    for (let i = 0; i < 16; i += 2) groups.push(((bytes[i] << 8) | bytes[i + 1]).toString(16));
    let bestStart = -1, bestLen = 0, curStart = -1;
    for (let i = 0; i <= groups.length; i++) {
      if (i < groups.length && groups[i] === "0") {
        if (curStart < 0) curStart = i;
      } else if (curStart >= 0) {
        const len = i - curStart;
        if (len > bestLen && len >= 2) { bestStart = curStart; bestLen = len; }
        curStart = -1;
      }
    }
    if (bestStart < 0) return groups.join(":");
    const left = groups.slice(0, bestStart).join(":");
    const right = groups.slice(bestStart + bestLen).join(":");
    return `${left}::${right}`;
  }

  function parseDns(bytes) {
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
      if (type === 1 && rdlen === 4) r.a = Array.from(bytes.slice(rstart,rend)).join(".");
      if (type === 28 && rdlen === 16) r.aaaa = ipv6Text(bytes.slice(rstart,rend));
      records.push(r); o = rend;
    }
    return records;
  }

  function run() {
    const mdnsHost = ipInput.value.trim();
    try { ipv4(mdnsHost); } catch (e) { logBox.textContent = `ERROR: ${e.message}`; return; }

    logBox.textContent = `mDNS responder ${mdnsHost}:5353`;
    runButton.disabled = true;
    let ws;
    let stream = new Uint8Array(0);
    let firstResponse = true;
    let serviceTarget = null;
    let servicePort = null;
    let sentAddressQueries = false;
    const aSet = new Set();
    const aaaaSet = new Set();

    const timer = setTimeout(() => {
      log(`SUMMARY target=${serviceTarget || "<none>"} port=${servicePort || "<none>"}`);
      log(`A=${aSet.size ? [...aSet].join(",") : "<none>"}`);
      log(`AAAA=${aaaaSet.size ? [...aaaaSet].join(",") : "<none>"}`);
      try { ws?.close(); } catch (_) {}
      runButton.disabled = false;
    }, 10000);

    try {
      ws = new WebSocket(WLOC_ADDR_WS_URL);
      ws.binaryType = "arraybuffer";
      ws.onopen = () => {
        log("WebSocket OPEN");
        const q = dnsQuery("_remotepairing._tcp.local", 12);
        ws.send(vlessUdpOpen(mdnsHost, 5353, q));
        log("Sent PTR _remotepairing._tcp.local");
      };
      ws.onmessage = (event) => {
        let chunk = new Uint8Array(event.data);
        if (firstResponse) {
          stream = concat(stream, chunk);
          if (stream.length < 2) return;
          const headerLength = 2 + stream[1];
          if (stream.length < headerLength) return;
          if (stream[0] !== 0) { log(`Unexpected VLESS version=${stream[0]}`); return; }
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
          try {
            for (const r of parseDns(datagram)) {
              if (r.ptr) log(`PTR ${r.name} -> ${r.ptr}`);
              if (r.port) {
                servicePort = r.port;
                serviceTarget = r.target;
                log(`SRV ${r.name} port=${r.port} target=${r.target}`);
              }
              if (r.a) { aSet.add(r.a); log(`A ${r.name} -> ${r.a}`); }
              if (r.aaaa) { aaaaSet.add(r.aaaa); log(`AAAA ${r.name} -> ${r.aaaa}`); }
            }
            if (serviceTarget && !sentAddressQueries) {
              sentAddressQueries = true;
              ws.send(udpFrame(dnsQuery(serviceTarget, 1)));
              ws.send(udpFrame(dnsQuery(serviceTarget, 28)));
              log(`Sent A + AAAA queries for ${serviceTarget}`);
            }
          } catch (e) { log(`DNS parse error: ${e?.message || e}`); }
        }
      };
      ws.onerror = () => log("WebSocket ERROR");
      ws.onclose = (event) => {
        clearTimeout(timer);
        log(`WebSocket CLOSED code=${event.code} reason=${event.reason || "<empty>"}`);
        log(`SUMMARY target=${serviceTarget || "<none>"} port=${servicePort || "<none>"}`);
        log(`A=${aSet.size ? [...aSet].join(",") : "<none>"}`);
        log(`AAAA=${aaaaSet.size ? [...aaaaSet].join(",") : "<none>"}`);
        runButton.disabled = false;
      };
    } catch (e) {
      clearTimeout(timer);
      log(`EXCEPTION: ${e?.message || e}`);
      runButton.disabled = false;
    }
  }

  runButton.onclick = run;
  closeButton.onclick = () => overlay.remove();
})();
