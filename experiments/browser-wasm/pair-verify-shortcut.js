// Run this with Safari -> Share -> Shortcuts -> Run JavaScript on Web Page.
// Open an HTTP page such as http://neverssl.com first so ws://127.0.0.1 is allowed.
// The selected .rppairing file stays in this page context and is passed only to WASM.

const REMOTE_PAIRING_PORT = 49152;
const BRIDGE_URL = "ws://127.0.0.1:17890/wloc";
const MODULE_URL = "https://raw.githack.com/xepes0/WLOC-CoreDevice-Lab/browser-wasm/experiments/browser-wasm/pkg/wloc_browser_wasm_probe.js";

let finished = false;
function finish(value) {
  if (finished) return;
  finished = true;
  completion(typeof value === "string" ? value : JSON.stringify(value));
}

try {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".rppairing,application/octet-stream";
  input.style.display = "none";
  document.documentElement.appendChild(input);

  input.onchange = async () => {
    try {
      const file = input.files && input.files[0];
      if (!file) {
        finish({ status: "CANCELLED", stage: "file-picker" });
        return;
      }

      if (file.name !== "WLOC-RPPairing.rppairing") {
        const proceed = confirm(`Selected ${file.name}. Continue with this pairing record?`);
        if (!proceed) {
          finish({ status: "CANCELLED", stage: "file-name-check" });
          return;
        }
      }

      const bytes = new Uint8Array(await file.arrayBuffer());
      const wasm = await import(MODULE_URL + `?v=${Date.now()}`);
      await wasm.default();

      const result = await wasm.pair_verify_localhost(
        bytes,
        REMOTE_PAIRING_PORT,
        BRIDGE_URL
      );
      finish(result);
    } catch (error) {
      finish({
        status: "ERROR",
        message: error && error.message ? error.message : String(error),
        stack: error && error.stack ? error.stack : ""
      });
    } finally {
      input.remove();
    }
  };

  input.oncancel = () => finish({ status: "CANCELLED", stage: "file-picker" });
  input.click();
} catch (error) {
  finish({ status: "ERROR", message: String(error) });
}
