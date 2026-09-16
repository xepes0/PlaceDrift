// WLOC Browser/WASM Pair Verify runner for iOS Safari Shortcuts.
// Run with: Safari -> Share -> your shortcut containing "Run JavaScript on Web Page".
// Open a plain HTTP page (for example http://neverssl.com) first so ws://127.0.0.1 is not blocked as mixed content.
// The selected .rppairing file is read only in the page context and passed directly to WASM.

const DEFAULT_REMOTE_PAIRING_PORT = 49152;
const BRIDGE_URL = "ws://127.0.0.1:17890/wloc";
const MODULE_URL = "https://raw.githack.com/xepes0/WLOC-CoreDevice-Lab/browser-wasm/experiments/browser-wasm/pkg/wloc_browser_wasm_probe.js";
const OVERLAY_ID = "wloc-pair-verify-overlay";

let finished = false;
function completeOnce(value) {
  if (finished) return;
  finished = true;
  completion(typeof value === "string" ? value : JSON.stringify(value));
}

function messageOf(error) {
  return error && error.message ? error.message : String(error);
}

try {
  document.getElementById(OVERLAY_ID)?.remove();

  const overlay = document.createElement("div");
  overlay.id = OVERLAY_ID;
  overlay.style.cssText = [
    "position:fixed",
    "z-index:2147483647",
    "left:12px",
    "right:12px",
    "top:calc(env(safe-area-inset-top, 0px) + 12px)",
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
    <div style="font-size:22px;font-weight:700;margin-bottom:8px">WLOC Pair Verify</div>
    <div style="font-size:14px;color:#555;line-height:1.4;margin-bottom:14px">
      Safari → Clash Mi VLESS/WebSocket → 127.0.0.1:&lt;RemotePairing port&gt; → CoreDevice Pair Verify
    </div>
    <label style="display:block;font-size:13px;color:#666;margin-bottom:4px">RemotePairing port</label>
    <input id="wloc-rp-port" inputmode="numeric" value="${DEFAULT_REMOTE_PAIRING_PORT}"
      style="width:100%;box-sizing:border-box;font-size:18px;padding:10px;border:1px solid #ccc;border-radius:10px;margin-bottom:12px">
    <input id="wloc-rp-file" type="file" accept=".rppairing,application/octet-stream" style="display:none">
    <button id="wloc-rp-choose" style="width:100%;font-size:17px;padding:12px;border:0;border-radius:10px;background:#e9e9ee;color:#111;margin-bottom:8px">
      选择 WLOC-RPPairing.rppairing
    </button>
    <div id="wloc-rp-name" style="font-size:13px;color:#666;word-break:break-all;margin:6px 0 12px">尚未选择文件</div>
    <button id="wloc-rp-run" disabled style="width:100%;font-size:17px;font-weight:600;padding:13px;border:0;border-radius:10px;background:#0a84ff;color:#fff;opacity:.45">
      Run Pair Verify
    </button>
    <button id="wloc-rp-cancel" style="width:100%;font-size:16px;padding:11px;border:0;border-radius:10px;background:#f2f2f7;color:#d00;margin-top:8px">
      取消
    </button>
    <pre id="wloc-rp-log" style="white-space:pre-wrap;word-break:break-word;background:#f5f5f7;border-radius:10px;padding:10px;margin:12px 0 0;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;min-height:42px">等待选择 pairing record…</pre>
  `;

  document.documentElement.appendChild(overlay);

  const fileInput = overlay.querySelector("#wloc-rp-file");
  const chooseButton = overlay.querySelector("#wloc-rp-choose");
  const runButton = overlay.querySelector("#wloc-rp-run");
  const cancelButton = overlay.querySelector("#wloc-rp-cancel");
  const nameBox = overlay.querySelector("#wloc-rp-name");
  const logBox = overlay.querySelector("#wloc-rp-log");
  const portInput = overlay.querySelector("#wloc-rp-port");

  let selectedFile = null;

  function setLog(text) {
    logBox.textContent = text;
  }

  chooseButton.onclick = () => fileInput.click();

  fileInput.onchange = () => {
    selectedFile = fileInput.files && fileInput.files[0] ? fileInput.files[0] : null;
    if (!selectedFile) {
      nameBox.textContent = "尚未选择文件";
      runButton.disabled = true;
      runButton.style.opacity = ".45";
      return;
    }
    nameBox.textContent = `${selectedFile.name} (${selectedFile.size} bytes)`;
    runButton.disabled = false;
    runButton.style.opacity = "1";
    setLog("Pairing record 已在本机选择，尚未发送。点击 Run Pair Verify 开始。\nBridge: " + BRIDGE_URL);
  };

  cancelButton.onclick = () => {
    overlay.remove();
    completeOnce({ status: "CANCELLED", stage: "ui" });
  };

  runButton.onclick = async () => {
    if (!selectedFile) return;

    const port = Number.parseInt(portInput.value, 10);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      setLog("ERROR: RemotePairing port 必须是 1-65535。 ");
      return;
    }

    runButton.disabled = true;
    runButton.style.opacity = ".45";
    chooseButton.disabled = true;
    portInput.disabled = true;

    try {
      setLog(`1/4 读取本地 pairing record…\n${selectedFile.name}`);
      const bytes = new Uint8Array(await selectedFile.arrayBuffer());

      setLog(`2/4 加载 CoreDevice WASM…\n${bytes.length} bytes`);
      const wasm = await import(MODULE_URL + `?v=${Date.now()}`);
      await wasm.default();

      setLog(`3/4 打开 ${BRIDGE_URL}\n目标 127.0.0.1:${port}\n等待 RemotePairing / Pair Verify…`);
      const result = await wasm.pair_verify_localhost(bytes, port, BRIDGE_URL);

      setLog(`4/4 SUCCESS\n${result}`);
      completeOnce(result);
    } catch (error) {
      const result = {
        status: "ERROR",
        stage: "pair-verify",
        remotePairingPort: port,
        message: messageOf(error),
        stack: error && error.stack ? error.stack : ""
      };
      setLog(JSON.stringify(result, null, 2));
      completeOnce(result);
    }
  };
} catch (error) {
  completeOnce({ status: "ERROR", stage: "bootstrap", message: messageOf(error) });
}
