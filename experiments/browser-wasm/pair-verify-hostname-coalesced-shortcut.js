// WLOC Browser/WASM Pair Verify using the Bonjour SRV target hostname.
// Rewrites the first VLESS TCP request from 127.0.0.1 to a DOMAIN address
// (default iPhone17ProMax.local) and coalesces idevice's first RPPairing frame
// into the same WebSocket message. This tests whether Mihomo/Darwin can resolve
// the Bonjour hostname to the scoped IPv6 link-local RemotePairing endpoint.

const WLOC_HOST_OVERLAY_ID = "wloc-pair-verify-hostname-coalesced-overlay";
const WLOC_HOST_BRIDGE = "ws://127.0.0.1:17890/wloc";
const WLOC_HOST_BUNDLE = "923edae7ef482e6788600addc1a1fa3b02bd84d5";
const WLOC_HOST_MODULE = `https://raw.githack.com/xepes0/WLOC-CoreDevice-Lab/${WLOC_HOST_BUNDLE}/experiments/browser-wasm/pkg/wloc_browser_wasm_probe.js`;
const WLOC_HOST_DEFAULT = "iPhone17ProMax.local";
const WLOC_HOST_DEFAULT_PORT = 49152;

(() => {
  document.getElementById(WLOC_HOST_OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_HOST_OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed","z-index:2147483647","left:12px","right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)","max-height:calc(100vh - 24px)",
    "overflow:auto","background:#fff","color:#111","border:1px solid #bbb",
    "border-radius:16px","box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px","font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC Pair Verify · Bonjour Hostname</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:8px">
      VLESS DOMAIN target + first RPPairing frame are sent together. This tests the SRV hostname path instead of IPv4/10.7.0.1.
    </div>
    <div style="font-size:12px;color:#888;margin-bottom:12px">bundle ${WLOC_HOST_BUNDLE.slice(0,12)}</div>
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">Bonjour SRV target</label>
    <input id="wloc-host-name" value="${WLOC_HOST_DEFAULT}" autocapitalize="off" autocomplete="off"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:10px">
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">RemotePairing port</label>
    <input id="wloc-host-port" inputmode="numeric" value="${WLOC_HOST_DEFAULT_PORT}"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:12px">
    <input id="wloc-host-file" type="file" accept=".rppairing,application/octet-stream" style="display:none">
    <button id="wloc-host-choose" style="width:100%;font-size:17px;padding:12px;border:0;border-radius:10px;background:#e9e9ee;color:#111;margin-bottom:8px">选择 WLOC-RPPairing.rppairing</button>
    <div id="wloc-host-file-name" style="font-size:13px;color:#666;word-break:break-all;margin:6px 0 12px">尚未选择文件</div>
    <button id="wloc-host-run" disabled style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;opacity:.45">Run Pair Verify to Bonjour Hostname</button>
    <button id="wloc-host-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-top:8px">关闭</button>
    <pre id="wloc-host-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:12px 0 0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:110px">等待选择 pairing record…</pre>
  `;
  document.documentElement.appendChild(overlay);

  const hostnameInput = overlay.querySelector("#wloc-host-name");
  const portInput = overlay.querySelector("#wloc-host-port");
  const fileInput = overlay.querySelector("#wloc-host-file");
  const chooseButton = overlay.querySelector("#wloc-host-choose");
  const runButton = overlay.querySelector("#wloc-host-run");
  const closeButton = overlay.querySelector("#wloc-host-close");
  const fileNameBox = overlay.querySelector("#wloc-host-file-name");
  const logBox = overlay.querySelector("#wloc-host-log");

  let selectedFile = null;
  const setLog = (text) => { logBox.textContent = text; };

  function bytesView(data) {
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return null;
  }

  function looksLikeInitialVless(view) {
    return !!view && view.length >= 26 &&
      view[0] === 0x00 &&
      view[17] === 0x00 &&
      view[18] === 0x01 &&
      view[21] === 0x01 &&
      view[22] === 127 && view[23] === 0 && view[24] === 0 && view[25] === 1;
  }

  function makeDomainHeader(originalView, hostname, port) {
    const encoded = new TextEncoder().encode(hostname);
    if (encoded.length < 1 || encoded.length > 255) throw new Error("Bonjour hostname 长度必须是 1-255 bytes");

    // VLESS request layout with optLen=0:
    // version[1] + uuid[16] + optLen[1] + command[1] + port[2] + addrType[1] + addr
    const header = new Uint8Array(23 + encoded.length);
    header.set(originalView.subarray(0, 22), 0);
    header[19] = (port >> 8) & 0xff;
    header[20] = port & 0xff;
    header[21] = 0x02; // domain
    header[22] = encoded.length;
    header.set(encoded, 23);
    return header;
  }

  chooseButton.onclick = () => fileInput.click();
  closeButton.onclick = () => overlay.remove();

  fileInput.onchange = () => {
    selectedFile = fileInput.files?.[0] || null;
    if (!selectedFile) {
      fileNameBox.textContent = "尚未选择文件";
      runButton.disabled = true;
      runButton.style.opacity = ".45";
      return;
    }
    fileNameBox.textContent = `${selectedFile.name} (${selectedFile.size} bytes)`;
    runButton.disabled = false;
    runButton.style.opacity = "1";
    setLog(`Pairing record 已在本机选择。\nBridge: ${WLOC_HOST_BRIDGE}\nBundle: ${WLOC_HOST_BUNDLE.slice(0,12)}`);
  };

  runButton.onclick = async () => {
    if (!selectedFile) return;

    const hostname = hostnameInput.value.trim();
    const port = Number.parseInt(portInput.value, 10);
    if (!hostname) {
      setLog("ERROR: Bonjour SRV target 不能为空");
      return;
    }
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      setLog("ERROR: RemotePairing port 必须是 1-65535");
      return;
    }

    runButton.disabled = true;
    runButton.style.opacity = ".45";
    chooseButton.disabled = true;
    hostnameInput.disabled = true;
    portInput.disabled = true;

    const originalSend = WebSocket.prototype.send;
    let pendingVlessHeader = null;
    let rewroteVlessHeader = false;
    let coalescedFirstPayload = false;
    let firstPayloadLength = 0;
    let rewrittenHeaderLength = 0;

    try {
      const bytes = new Uint8Array(await selectedFile.arrayBuffer());
      setLog(`1/4 pairing record ${bytes.length} bytes\n2/4 加载 WASM bundle ${WLOC_HOST_BUNDLE.slice(0,12)}…`);
      const wasm = await import(WLOC_HOST_MODULE);
      await wasm.default();

      WebSocket.prototype.send = function(data) {
        const view = bytesView(data);

        if (!pendingVlessHeader && !rewroteVlessHeader && this.url === WLOC_HOST_BRIDGE && looksLikeInitialVless(view)) {
          const header = makeDomainHeader(view, hostname, port);
          pendingVlessHeader = header;
          rewrittenHeaderLength = header.length;
          rewroteVlessHeader = true;
          setLog(
            `3/4 VLESS header 已改写为 DOMAIN 并缓存。\n` +
            `target=${hostname}:${port}\n` +
            `header=${header.length} bytes\n等待首个 RPPairing payload…`
          );
          return undefined;
        }

        if (pendingVlessHeader && this.url === WLOC_HOST_BRIDGE && view) {
          const combined = new Uint8Array(pendingVlessHeader.length + view.length);
          combined.set(pendingVlessHeader, 0);
          combined.set(view, pendingVlessHeader.length);
          firstPayloadLength = view.length;
          pendingVlessHeader = null;
          coalescedFirstPayload = true;
          setLog(
            `3/4 COALESCED DOMAIN SEND\n` +
            `target=${hostname}:${port}\n` +
            `VLESS domain header=${rewrittenHeaderLength} bytes\n` +
            `first RPPairing payload=${view.length} bytes\n` +
            `combined=${combined.length} bytes\n等待 Pair Verify 响应…`
          );
          return originalSend.call(this, combined);
        }

        return originalSend.call(this, data);
      };

      const result = await wasm.pair_verify_localhost(bytes, port, WLOC_HOST_BRIDGE);
      setLog(
        `4/4 SUCCESS\n` +
        `Actual target: ${hostname}:${port}\n` +
        `VLESS domain rewrite applied: ${rewroteVlessHeader}\n` +
        `Domain header bytes: ${rewrittenHeaderLength}\n` +
        `First payload coalesced: ${coalescedFirstPayload}\n` +
        `First payload bytes: ${firstPayloadLength}\n${result}`
      );
    } catch (error) {
      setLog(JSON.stringify({
        status: "ERROR",
        stage: "pair-verify-hostname-coalesced",
        actualTarget: `${hostname}:${port}`,
        vlessDomainRewriteApplied: rewroteVlessHeader,
        rewrittenHeaderBytes: rewrittenHeaderLength,
        firstPayloadCoalesced: coalescedFirstPayload,
        firstPayloadBytes: firstPayloadLength,
        pendingHeaderStillBuffered: !!pendingVlessHeader,
        bundleCommit: WLOC_HOST_BUNDLE,
        message: error?.message || String(error),
        stack: error?.stack || ""
      }, null, 2));
    } finally {
      WebSocket.prototype.send = originalSend;
      runButton.disabled = false;
      runButton.style.opacity = "1";
      chooseButton.disabled = false;
      hostnameInput.disabled = false;
      portInput.disabled = false;
    }
  };
})();
