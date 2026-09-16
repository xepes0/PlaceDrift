#![allow(dead_code)]

use idevice::ReadWrite;
use idevice::RsdService;
use idevice::dvt::{
    location_simulation::LocationSimulationClient,
    remote_server::RemoteServerClient,
};
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocketProvider};
use idevice::rsd::RsdHandshake;

pub fn wasm_api_surface_marker() -> usize {
    core::mem::size_of::<RpPairingFile>() + core::mem::size_of::<RsdHandshake>()
}

fn _require_transport<T: ReadWrite>(_transport: &T) {}
fn _require_rsd<T: RsdService>() {}

fn _type_surface<T>()
where
    T: ReadWrite + RpPairingSocketProvider + 'static,
{
    let _ = core::mem::size_of::<Option<RemotePairingClient<T>>>();
    let _ = core::mem::size_of::<Option<RemoteServerClient<T>>>();
    let _ = core::mem::size_of::<Option<LocationSimulationClient<'static, T>>>();
}

#[cfg(target_arch = "wasm32")]
mod browser {
    use std::collections::VecDeque;
    use std::fmt;
    use std::future::Future;
    use std::io;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
    use js_sys::Uint8Array;
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
    use wasm_bindgen::prelude::*;
    use wasm_bindgen_futures::JsFuture;

    const DEFAULT_BRIDGE_URL: &str = "ws://127.0.0.1:17890/wloc";
    const VLESS_UUID: [u8; 16] = [
        0xb8, 0x84, 0x2e, 0x9c, 0x72, 0xfd, 0x4a, 0x59,
        0x9f, 0x8d, 0x5f, 0x3b, 0x9e, 0x9b, 0x5d, 0x2a,
    ];

    #[wasm_bindgen(inline_js = r#"
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
"#)]
    extern "C" {
        #[wasm_bindgen(js_name = wlocWsOpen)]
        fn js_ws_open(url: &str) -> js_sys::Promise;

        #[wasm_bindgen(catch, js_name = wlocWsSend)]
        fn js_ws_send(handle: u32, data: &[u8]) -> Result<(), JsValue>;

        #[wasm_bindgen(js_name = wlocWsRecv)]
        fn js_ws_recv(handle: u32) -> js_sys::Promise;

        #[wasm_bindgen(js_name = wlocWsClose)]
        fn js_ws_close(handle: u32);
    }

    pub struct VlessWebSocketTransport {
        handle: u32,
        incoming: VecDeque<u8>,
        receive: Option<Pin<Box<JsFuture>>>,
        response_header: Vec<u8>,
        response_header_done: bool,
        closed: bool,
    }

    impl fmt::Debug for VlessWebSocketTransport {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.debug_struct("VlessWebSocketTransport")
                .field("handle", &self.handle)
                .field("queued_bytes", &self.incoming.len())
                .field("response_header_done", &self.response_header_done)
                .field("closed", &self.closed)
                .finish()
        }
    }

    // wasm32-unknown-unknown is single-threaded in this PoC. `idevice::ReadWrite`
    // requires Send + Sync, while JsFuture is intentionally !Send on native Rust.
    // The transport is never transferred to a Web Worker or shared-memory thread.
    unsafe impl Send for VlessWebSocketTransport {}
    unsafe impl Sync for VlessWebSocketTransport {}

    impl VlessWebSocketTransport {
        async fn connect(bridge_url: &str, target_port: u16) -> Result<Self, String> {
            let handle_value = JsFuture::from(js_ws_open(bridge_url))
                .await
                .map_err(js_error_string)?;
            let handle = handle_value
                .as_f64()
                .ok_or_else(|| "WebSocket bridge returned an invalid handle".to_string())?
                as u32;

            let request = vless_tcp_request(target_port);
            if let Err(error) = js_ws_send(handle, &request) {
                js_ws_close(handle);
                return Err(js_error_string(error));
            }

            Ok(Self {
                handle,
                incoming: VecDeque::new(),
                receive: None,
                response_header: Vec::new(),
                response_header_done: false,
                closed: false,
            })
        }

        fn feed_websocket_message(&mut self, bytes: Vec<u8>) -> io::Result<()> {
            if self.response_header_done {
                self.incoming.extend(bytes);
                return Ok(());
            }

            self.response_header.extend(bytes);
            if self.response_header.len() < 2 {
                return Ok(());
            }

            let version = self.response_header[0];
            if version != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("unexpected VLESS response version {version}"),
                ));
            }

            let header_len = 2 + self.response_header[1] as usize;
            if self.response_header.len() < header_len {
                return Ok(());
            }

            let payload = self.response_header.split_off(header_len);
            self.response_header.clear();
            self.response_header_done = true;
            self.incoming.extend(payload);
            Ok(())
        }

        fn io_error(&self, value: JsValue) -> io::Error {
            io::Error::new(
                io::ErrorKind::ConnectionAborted,
                format!(
                    "{}; vlessResponseHeaderDone={}; queuedBytes={}",
                    js_error_string(value),
                    self.response_header_done,
                    self.incoming.len()
                ),
            )
        }
    }

    impl Drop for VlessWebSocketTransport {
        fn drop(&mut self) {
            if !self.closed {
                self.closed = true;
                js_ws_close(self.handle);
            }
        }
    }

    impl AsyncRead for VlessWebSocketTransport {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            loop {
                if !self.incoming.is_empty() {
                    let count = buf.remaining().min(self.incoming.len());
                    let mut chunk = Vec::with_capacity(count);
                    for _ in 0..count {
                        if let Some(byte) = self.incoming.pop_front() {
                            chunk.push(byte);
                        }
                    }
                    buf.put_slice(&chunk);
                    return Poll::Ready(Ok(()));
                }

                if self.closed {
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        format!(
                            "WLOC WebSocket transport is closed; vlessResponseHeaderDone={}",
                            self.response_header_done
                        ),
                    )));
                }

                if self.receive.is_none() {
                    self.receive = Some(Box::pin(JsFuture::from(js_ws_recv(self.handle))));
                }

                let poll = {
                    let future = self.receive.as_mut().expect("receive future");
                    Future::poll(future.as_mut(), cx)
                };

                match poll {
                    Poll::Pending => return Poll::Pending,
                    Poll::Ready(Err(error)) => {
                        self.receive = None;
                        let io_error = self.io_error(error);
                        self.closed = true;
                        return Poll::Ready(Err(io_error));
                    }
                    Poll::Ready(Ok(value)) => {
                        self.receive = None;
                        let array = Uint8Array::new(&value);
                        let mut bytes = vec![0u8; array.length() as usize];
                        array.copy_to(&mut bytes);
                        if let Err(error) = self.feed_websocket_message(bytes) {
                            return Poll::Ready(Err(error));
                        }
                    }
                }
            }
        }
    }

    impl AsyncWrite for VlessWebSocketTransport {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            if self.closed {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "WLOC WebSocket transport is closed",
                )));
            }
            match js_ws_send(self.handle, buf) {
                Ok(()) => Poll::Ready(Ok(buf.len())),
                Err(error) => Poll::Ready(Err(self.io_error(error))),
            }
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            if !self.closed {
                self.closed = true;
                js_ws_close(self.handle);
            }
            Poll::Ready(Ok(()))
        }
    }

    #[wasm_bindgen]
    pub async fn pair_verify_localhost(
        pairing_record: Vec<u8>,
        remote_pairing_port: u16,
        bridge_url: Option<String>,
    ) -> Result<String, JsValue> {
        if pairing_record.is_empty() {
            return Err(js_error("Pairing record is empty"));
        }
        if remote_pairing_port == 0 {
            return Err(js_error("RemotePairing port must be non-zero"));
        }

        let mut pairing_file = RpPairingFile::from_bytes(&pairing_record)
            .map_err(|error| js_error(format!("Could not parse pairing record: {error:?}")))?;
        let bridge_url = bridge_url.unwrap_or_else(|| DEFAULT_BRIDGE_URL.to_string());
        let transport = VlessWebSocketTransport::connect(&bridge_url, remote_pairing_port)
            .await
            .map_err(js_error)?;

        let socket = RpPairingSocket::new(transport);
        let mut client = RemotePairingClient::new(socket, "WLOC Browser PoC");

        client
            .attempt_pair_verify()
            .await
            .map_err(|error| js_error(format!("attemptPairVerify failed: {error:?}")))?;
        client
            .validate_pairing(&mut pairing_file)
            .await
            .map_err(|error| js_error(format!("Pair Verify failed: {error:?}")))?;

        Ok(serde_json::json!({
            "status": "PAIR_VERIFY_OK",
            "remotePairingHost": "127.0.0.1",
            "remotePairingPort": remote_pairing_port,
            "bridge": bridge_url,
            "encryptionKeyLength": client.encryption_key().len()
        })
        .to_string())
    }

    fn vless_tcp_request(port: u16) -> Vec<u8> {
        let mut request = Vec::with_capacity(26);
        request.push(0x00); // VLESS version
        request.extend_from_slice(&VLESS_UUID);
        request.push(0x00); // addon length
        request.push(0x01); // TCP
        request.extend_from_slice(&port.to_be_bytes());
        request.push(0x01); // IPv4
        request.extend_from_slice(&[127, 0, 0, 1]);
        request
    }

    fn js_error(message: impl AsRef<str>) -> JsValue {
        js_sys::Error::new(message.as_ref()).into()
    }

    fn js_error_string(value: JsValue) -> String {
        value
            .as_string()
            .or_else(|| js_sys::Reflect::get(&value, &JsValue::from_str("message")).ok()?.as_string())
            .unwrap_or_else(|| format!("{value:?}"))
    }
}

#[cfg(target_arch = "wasm32")]
pub use browser::pair_verify_localhost;
