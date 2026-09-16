
const REGISTRY_KEY = '__wlocCoreDeviceWsRegistry';
const NEXT_KEY = '__wlocCoreDeviceWsNextId';

function registry() {
  if (!globalThis[REGISTRY_KEY]) globalThis[REGISTRY_KEY] = new Map();
  if (!globalThis[NEXT_KEY]) globalThis[NEXT_KEY] = 1;
  return globalThis[REGISTRY_KEY];
}

function rejectWaiters(entry, error) {
  const waiters = entry.waiters.splice(0);
  for (const waiter of waiters) waiter.reject(error);
}

export function wlocWsOpen(url) {
  return new Promise((resolve, reject) => {
    const id = globalThis[NEXT_KEY] || 1;
    globalThis[NEXT_KEY] = id + 1;

    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    const entry = { ws, queue: [], waiters: [], opened: false, sawError: false };
    registry().set(id, entry);

    ws.onopen = () => {
      entry.opened = true;
      resolve(id);
    };

    ws.onmessage = (event) => {
      const bytes = event.data instanceof ArrayBuffer
        ? new Uint8Array(event.data)
        : new Uint8Array(event.data.buffer, event.data.byteOffset, event.data.byteLength);
      const copy = new Uint8Array(bytes);
      const waiter = entry.waiters.shift();
      if (waiter) waiter.resolve(copy);
      else entry.queue.push(copy);
    };

    ws.onerror = () => {
      entry.sawError = true;
      const error = new Error('WLOC WebSocket transport error before OPEN');
      if (!entry.opened) reject(error);
      // If the socket was already open, wait for onclose so callers get the
      // close code/reason instead of losing the useful downstream-dial detail.
    };

    ws.onclose = (event) => {
      const suffix = entry.sawError ? ', sawError=true' : '';
      rejectWaiters(entry, new Error(`WLOC WebSocket closed code=${event.code} reason=${event.reason || '<empty>'}${suffix}`));
      registry().delete(id);
    };
  });
}

export function wlocWsSend(id, data) {
  const entry = registry().get(id);
  if (!entry || entry.ws.readyState !== WebSocket.OPEN) {
    throw new Error('WLOC WebSocket is not open');
  }
  entry.ws.send(data);
}

export function wlocWsRecv(id) {
  const entry = registry().get(id);
  if (!entry) return Promise.reject(new Error('WLOC WebSocket handle is closed'));
  if (entry.queue.length) return Promise.resolve(entry.queue.shift());
  return new Promise((resolve, reject) => entry.waiters.push({ resolve, reject }));
}

export function wlocWsClose(id) {
  const entry = registry().get(id);
  if (!entry) return;
  try { entry.ws.close(); } catch (_) {}
  rejectWaiters(entry, new Error('WLOC WebSocket closed by client'));
  registry().delete(id);
}
