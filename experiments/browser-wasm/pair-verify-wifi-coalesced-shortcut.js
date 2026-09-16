// WLOC Browser/WASM Pair Verify over the iPhone's current Wi-Fi IPv4 address.
// Experimental transport fix: buffer the first VLESS TCP request and coalesce it
// with idevice's first RPPairing frame into ONE WebSocket send. This tests whether
// RemotePairing closes idle TCP sessions before a separate second WS frame arrives.

const WLOC_COAL_OVERLAY_ID = "wloc-pair-verify-wifi-coalesced-overlay";
const WLOC_COAL_BRIDGE = "ws://127.0.0.1:17890/wloc";
const WLOC_COAL_BUNDLE = "923edae7ef482e6788600addc1a1fa3b02bd84d5";
const WLOC_COAL_MODULE = `https://raw.githack.com/xepes0/WLOC-CoreDevice-Lab/${WLOC_COAL_BUNDLE}/experiments/browser-wasm/pkg/wloc_browser_wasm_probe.js`;
const WLOC_COAL_DEFAULT_HOST = "192.168.10.40";
const WLOC_COAL_DEFAULT_PORT = 49152;

(() => {
  document.getElementById(WLOC_COAL_OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = WLOC_COAL_OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed","z-index:2147483647","left:12px","right:12px",
    "top:calc(env(safe-area-inset-top,0px) + 12px)","max-height:calc(100vh - 24px)",
    "overflow:auto","background:#fff","color:#111","border:1px solid #bbb",
    "border-radius:16px","box-shadow:0 12px 40px rgba(0,0,0,.28)",
    "padding:18px","font:16px -apple-system,BlinkMacSystemFont,sans-serif"
  ].join(";");

  overlay.innerHTML = `
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC Pair Verify · Coalesced First Frame</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:8px">
      VLESS header + first RPPairing frame are sent together in one WebSocket message.
    </div>
    <div style="font-size:12px;color:#888;margin-bottom:12px">bundle ${WLOC_COAL_BUNDLE.slice(0,12)}</div>
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">iPhone Wi-Fi IPv4</label>
    <input id="wloc-coal-host" value="${WLOC_COAL_DEFAULT_HOST}" autocapitalize="off" autocomplete="off"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:10px">
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">RemotePairing port</label>
    <input id="wloc-coal-port" inputmode="numeric" value="${WLOC_COAL_DEFAULT_PORT}"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:12px">
    <input id="wloc-coal-file" type="file" accept=".rppairing,application/octet-stream" style="display:none">
    <button id="wloc-coal-choose" style="width:100%;font-size:17px;padding:12px;border:0;border-radius:10px;background:#e9e9ee;color:#111;margin-bottom:8px">选择 WLOC-RPPairing.rppairing</button>
    <div id="wloc-coal-name" style="font-size:13px;color:#666;word-break:break-all;margin:6px 0 12px">尚未选择文件</div>
    <button id="wloc-coal-run" disabled style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;opacity:.45">Run Coalesced Pair Verify</button>
    <button id="wloc-coal-close" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-top:8px">关闭</button>
    <pre id="wloc-coal-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:12px 0 0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:110px">等待选择 pairing record…</pre>
  `;
  document.documentElement.appendChild(overlay);

  const hostInput = overlay.querySelector("#wloc-coal-host");
  const portInput = overlay.querySelector("#wloc-coal-port");
  const fileInput = overlay.querySelector("#wloc-coal-file");
  const chooseButton = overlay.querySelector("#wloc-coal-choose");
  const runButton = overlay.querySelector("#wloc-coal-run");
  const closeButton = overlay.querySelector("#wloc-coal-close");
  const nameBox = overlay.querySelector("#wloc-coal-name");
  const logBox = overlay.querySelector("#wloc-coal-log");

  let selectedFile = null;
  const setLog = (text) => { logBox.textContent = text; };

  function parseIPv4(value) {
    const parts = value.trim().split(".").map(Number);
    if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
      throw new Error("iPhone Wi-Fi IPv4 格式不正确");
    }
    return parts;
  }

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

  chooseButton.onclick = () => fileInput.click();
  closeButton.onclick = () => overlay.remove();

  fileInput.onchange = () => {
    selectedFile = fileInput.files?.[0] || null;
    if (!selectedFile) {
      nameBox.textContent = "尚未选择文件";
      runButton.disabled = true;
      runButton.style.opacity = ".45";
      return;
    }
    nameBox.textContent = `${selectedFile.name} (${selectedFile.size} bytes)`;
    runButton.disabled = false;
    runButton.style.opacity = "1";
    setLog(`Pairing record 已在本机选择。\nBridge: ${WLOC_COAL_BRIDGE}\nBundle: ${WLOC_COAL_BUNDLE.slice(0,12)}`);
  };

  runButton.onclick = async () => {
    if (!selectedFile) return;

    let targetIp;
    let port;
    try {
      targetIp = parseIPv4(hostInput.value);
      port = Number.parseInt(portInput.value, 10);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("RemotePairing port 必须是 1-65535");
    } catch (error) {
      setLog(`ERROR: ${error.message || error}`);
      return;
    }

    runButton.disabled = true;
    runButton.style.opacity = ".45";
    chooseButton.disabled = true;
    hostInput.disabled = true;
    portInput.disabled = true;

    const originalSend = WebSocket.prototype.send;
    let pendingVlessHeader = null;
    let rewroteVlessHeader = false;
    let coalescedFirstPayload = false;
    let firstPayloadLength = 0;

    try {
      const bytes = new Uint8Array(await selectedFile.arrayBuffer());
      setLog(`1/4 pairing record ${bytes.length} bytes\n2/4 加载 WASM bundle ${WLOC_COAL_BUNDLE.slice(0,12)}…`);
      const wasm = await import(WLOC_COAL_MODULE);
      await wasm.default();

      WebSocket.prototype.send = function(data) {
        const view = bytesView(data);

        if (!pendingVlessHeader && !rewroteVlessHeader && this.url === WLOC_COAL_BRIDGE && looksLikeInitialVless(view)) {
          const header = new Uint8Array(view);
          header[22] = targetIp[0];
          header[23] = targetIp[1];
          header[24] = targetIp[2];
          header[25] = targetIp[3];
          pendingVlessHeader = header;
          rewroteVlessHeader = true;
          setLog(
            `3/4 VLESS header 已缓存，等待首个 RPPairing payload…\n` +
            `127.0.0.1:${port} → ${targetIp.join(".")}:${port}\n` +
            `不会先单独建立空 TCP。`
          );
          return undefined;
        }

        if (pendingVlessHeader && this.url === WLOC_COAL_BRIDGE && view) {
          const combined = new Uint8Array(pendingVlessHeader.length + view.length);
          combined.set(pendingVlessHeader, 0);
          combined.set(view, pendingVlessHeader.length);
          firstPayloadLength = view.length;
          pendingVlessHeader = null;
          coalescedFirstPayload = true;
          setLog(
            `3/4 COALESCED SEND\n` +
            `target=${targetIp.join(".")}:${port}\n` +
            `VLESS header=26 bytes\nfirst RPPairing payload=${view.length} bytes\n` +
            `combined=${combined.length} bytes\n等待 Pair Verify 响应…`
          );
          return originalSend.call(this, combined);
        }

        return originalSend.call(this, data);
      };

      const result = await wasm.pair_verify_localhost(bytes, port, WLOC_COAL_BRIDGE);
      setLog(
        `4/4 SUCCESS\n` +
        `Actual target: ${targetIp.join(".")}:${port}\n` +
        `VLESS rewrite applied: ${rewroteVlessHeader}\n` +
        `First payload coalesced: ${coalescedFirstPayload}\n` +
        `First payload bytes: ${firstPayloadLength}\n${result}`
      );
    } catch (error) {
      setLog(JSON.stringify({
        status: "ERROR",
        stage: "pair-verify-wifi-coalesced",
        actualTarget: `${targetIp.join(".")}:${port}`,
        vlessRewriteApplied: rewroteVlessHeader,
        firstPayloadCoalesced: coalescedFirstPayload,
        firstPayloadBytes: firstPayloadLength,
        pendingHeaderStillBuffered: !!pendingVlessHeader,
        bundleCommit: WLOC_COAL_BUNDLE,
        message: error?.message || String(error),
        stack: error?.stack || ""
      }, null, 2));
    } finally {
      WebSocket.prototype.send = originalSend;
      runButton.disabled = false;
      runButton.style.opacity = "1";
      chooseButton.disabled = false;
      hostInput.disabled = false;
      portInput.disabled = false;
    }
  };
})();
