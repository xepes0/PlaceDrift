use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::dvt::{
    location_simulation::LocationSimulationClient,
    remote_server::RemoteServerClient,
};
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile,
    RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::{RsdService, tcp};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{Instant, sleep, timeout};

const DEFAULT_HOST_NAME: &str = "WLOC CoreDevice Probe";
const DEFAULT_HOST_MODEL: &str = "Mac17,7";
const DEFAULT_PEER_ADDRESS: &str = "10.7.0.1";
const SESSION_TIMEOUT: Duration = Duration::from_secs(15);

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FailureStage {
    None = 0,
    PairingRecord = 1,
    ServiceIdentity = 2,
    PairVerify = 3,
    SecureTunnel = 4,
    Rsd = 5,
    Dvt = 6,
    LocationSimulation = 7,
    Clear = 8,
    PairingHost = 9,
    Cancelled = 10,
    Internal = 255,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct EngineStatus {
    pub code: i32,
    pub failure_stage: u32,
}

impl EngineStatus {
    pub const fn ok() -> Self {
        Self {
            code: 0,
            failure_stage: FailureStage::None as u32,
        }
    }

    pub const fn failed(stage: FailureStage) -> Self {
        Self {
            code: 1,
            failure_stage: stage as u32,
        }
    }
}

#[derive(Debug)]
struct StageError {
    stage: FailureStage,
    message: String,
}

impl StageError {
    fn new(stage: FailureStage, message: impl Into<String>) -> Self {
        Self {
            stage,
            message: message.into(),
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
struct Coordinates {
    latitude: f64,
    longitude: f64,
}

impl Coordinates {
    fn validated(latitude: f64, longitude: f64) -> Result<Self, StageError> {
        if latitude.is_finite()
            && longitude.is_finite()
            && (-90.0..=90.0).contains(&latitude)
            && (-180.0..=180.0).contains(&longitude)
        {
            Ok(Self { latitude, longitude })
        } else {
            Err(StageError::new(
                FailureStage::LocationSimulation,
                "Coordinates are outside the valid range.",
            ))
        }
    }
}

pub type PairingReadyCallback = Option<
    extern "C" fn(
        context: *mut c_void,
        service_identifier: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_values: *const *const c_char,
        txt_count: usize,
    ),
>;
pub type PairingPinCallback = Option<extern "C" fn(context: *mut c_void, pin: *const c_char)>;
pub type LocationStartedCallback = Option<extern "C" fn(context: *mut c_void)>;

#[repr(C)]
pub struct PairingSession {
    cancelled: Arc<AtomicBool>,
}

#[repr(C)]
pub struct LocationSession {
    cancelled: Arc<AtomicBool>,
    coordinates: Arc<Mutex<Coordinates>>,
}

#[repr(C)]
pub struct PairingResult {
    pub error_message: *mut c_char,
    pub failure_stage: u32,
    pub pairing_record: *mut u8,
    pub pairing_record_length: usize,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
}

#[repr(C)]
pub struct LocationResult {
    pub error_message: *mut c_char,
    pub failure_stage: u32,
}

impl PairingResult {
    fn empty() -> Self {
        Self {
            error_message: ptr::null_mut(),
            failure_stage: FailureStage::None as u32,
            pairing_record: ptr::null_mut(),
            pairing_record_length: 0,
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
        }
    }
}

impl LocationResult {
    fn empty() -> Self {
        Self {
            error_message: ptr::null_mut(),
            failure_stage: FailureStage::None as u32,
        }
    }
}

struct CallbackSet {
    ready: PairingReadyCallback,
    pin: PairingPinCallback,
    context: *mut c_void,
}

unsafe impl Send for CallbackSet {}

struct CompletedPairing {
    pairing_record: Vec<u8>,
    device_name: String,
    device_model: String,
}

#[unsafe(no_mangle)]
pub extern "C" fn wloc_coredevice_validate_coordinates(latitude: f64, longitude: f64) -> EngineStatus {
    match Coordinates::validated(latitude, longitude) {
        Ok(_) => EngineStatus::ok(),
        Err(error) => EngineStatus::failed(error.stage),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn wloc_pairing_session_create() -> *mut PairingSession {
    Box::into_raw(Box::new(PairingSession {
        cancelled: Arc::new(AtomicBool::new(false)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_cancel(session: *mut PairingSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_destroy(session: *mut PairingSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_session_run(
    session: *mut PairingSession,
    ready_callback: PairingReadyCallback,
    pin_callback: PairingPinCallback,
    context: *mut c_void,
    result: *mut PairingResult,
) -> i32 {
    if session.is_null() || result.is_null() {
        return 2;
    }

    unsafe { *result = PairingResult::empty() };
    let session = unsafe { &*session };
    session.cancelled.store(false, Ordering::Release);
    let callbacks = CallbackSet {
        ready: ready_callback,
        pin: pin_callback,
        context,
    };
    let cancellation = Arc::clone(&session.cancelled);

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| StageError::new(FailureStage::Internal, "Could not start pairing runtime."))?;
        runtime.block_on(run_pairing(callbacks, cancellation))
    }));

    match execution {
        Ok(Ok(completed)) => {
            let (record, length) = owned_byte_buffer(completed.pairing_record);
            unsafe {
                (*result).pairing_record = record;
                (*result).pairing_record_length = length;
                (*result).device_name = owned_c_string(completed.device_name);
                (*result).device_model = owned_c_string(completed.device_model);
            }
            0
        }
        Ok(Err(error)) => {
            unsafe {
                (*result).failure_stage = error.stage as u32;
                (*result).error_message = owned_c_string(error.message);
            }
            1
        }
        Err(_) => {
            unsafe {
                (*result).failure_stage = FailureStage::Internal as u32;
                (*result).error_message = owned_c_string("Pairing engine stopped unexpectedly.");
            }
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_result_destroy(result: *mut PairingResult) {
    let Some(result) = (unsafe { result.as_mut() }) else { return };
    for value in [result.error_message, result.device_name, result.device_model] {
        if !value.is_null() {
            unsafe { drop(CString::from_raw(value)) };
        }
    }
    unsafe { destroy_byte_buffer(result.pairing_record, result.pairing_record_length) };
    *result = PairingResult::empty();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_pairing_record_matches_service(
    pairing_record: *const u8,
    pairing_record_length: usize,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
) -> i32 {
    if pairing_record.is_null()
        || pairing_record_length == 0
        || service_identifier.is_null()
        || auth_tag.is_null()
    {
        return 0;
    }

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(pairing_record, pairing_record_length) };
        let Ok(pairing_file) = RpPairingFile::from_bytes(bytes) else { return false };
        let Some(alt_irk) = pairing_file.alt_irk() else { return false };
        let Ok(identifier) = (unsafe { CStr::from_ptr(service_identifier) }).to_str() else {
            return false;
        };
        let Ok(auth_tag) = (unsafe { CStr::from_ptr(auth_tag) }).to_str() else {
            return false;
        };
        PeerDevice::validate_auth_tag(alt_irk, identifier.trim(), auth_tag.trim())
    }));
    matches!(execution, Ok(true)) as i32
}

#[unsafe(no_mangle)]
pub extern "C" fn wloc_location_session_create() -> *mut LocationSession {
    Box::into_raw(Box::new(LocationSession {
        cancelled: Arc::new(AtomicBool::new(false)),
        coordinates: Arc::new(Mutex::new(Coordinates {
            latitude: 0.0,
            longitude: 0.0,
        })),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_update(
    session: *mut LocationSession,
    latitude: f64,
    longitude: f64,
) -> i32 {
    let Some(session) = (unsafe { session.as_ref() }) else { return 2 };
    let Ok(next) = Coordinates::validated(latitude, longitude) else { return 1 };
    let Ok(mut current) = session.coordinates.lock() else { return 2 };
    *current = next;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_cancel(session: *mut LocationSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_destroy(session: *mut LocationSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_session_run(
    session: *mut LocationSession,
    pairing_record: *const u8,
    pairing_record_length: usize,
    peer_address: *const c_char,
    remote_pairing_port: u16,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
    latitude: f64,
    longitude: f64,
    started_callback: LocationStartedCallback,
    context: *mut c_void,
    result: *mut LocationResult,
) -> i32 {
    if session.is_null()
        || result.is_null()
        || pairing_record.is_null()
        || pairing_record_length == 0
        || service_identifier.is_null()
        || auth_tag.is_null()
    {
        return 2;
    }

    unsafe { *result = LocationResult::empty() };
    let session = unsafe { &*session };
    session.cancelled.store(false, Ordering::Release);
    let pairing_record = unsafe {
        std::slice::from_raw_parts(pairing_record, pairing_record_length).to_vec()
    };
    let peer_address = unsafe { optional_c_string(peer_address, DEFAULT_PEER_ADDRESS) };
    let service_identifier = unsafe { optional_c_string(service_identifier, "") };
    let auth_tag = unsafe { optional_c_string(auth_tag, "") };
    let Ok(initial_coordinates) = Coordinates::validated(latitude, longitude) else {
        unsafe { (*result).failure_stage = FailureStage::LocationSimulation as u32 };
        return 1;
    };
    if let Ok(mut current) = session.coordinates.lock() {
        *current = initial_coordinates;
    }

    let cancellation = Arc::clone(&session.cancelled);
    let coordinates = Arc::clone(&session.coordinates);
    let callback_context = context as usize;

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .enable_all()
            .build()
            .map_err(|_| StageError::new(FailureStage::Internal, "Could not start device runtime."))?;
        runtime.block_on(run_location_session(
            pairing_record,
            peer_address,
            remote_pairing_port,
            service_identifier,
            auth_tag,
            coordinates,
            started_callback,
            callback_context,
            cancellation,
        ))
    }));

    match execution {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            unsafe {
                (*result).failure_stage = error.stage as u32;
                (*result).error_message = owned_c_string(error.message);
            }
            1
        }
        Err(_) => {
            unsafe {
                (*result).failure_stage = FailureStage::Internal as u32;
                (*result).error_message = owned_c_string("Location engine stopped unexpectedly.");
            }
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn wloc_location_result_destroy(result: *mut LocationResult) {
    let Some(result) = (unsafe { result.as_mut() }) else { return };
    if !result.error_message.is_null() {
        unsafe { drop(CString::from_raw(result.error_message)) };
    }
    *result = LocationResult::empty();
}

async fn run_pairing(
    callbacks: CallbackSet,
    cancellation: Arc<AtomicBool>,
) -> Result<CompletedPairing, StageError> {
    check_cancelled(&cancellation)?;
    let listener = TcpListener::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0))
        .await
        .map_err(|_| StageError::new(FailureStage::PairingHost, "Could not open pairing listener."))?;
    let port = listener
        .local_addr()
        .map_err(|_| StageError::new(FailureStage::PairingHost, "Could not read pairing port."))?
        .port();

    let mut pairing_record = RpPairingFile::generate(DEFAULT_HOST_NAME);
    let host_info = PairableHostInfo::generate(DEFAULT_HOST_NAME, DEFAULT_HOST_MODEL);
    publish_ready_callback(&callbacks, &pairing_record.identifier, port, &host_info);

    let (stream, _) = tokio::select! {
        accepted = listener.accept() => accepted
            .map_err(|_| StageError::new(FailureStage::PairingHost, "The iPhone did not open the pairing connection."))?,
        _ = wait_for_cancellation(Arc::clone(&cancellation)) => {
            return Err(StageError::new(FailureStage::Cancelled, "Pairing cancelled."));
        }
    };

    let pin_callback = callbacks.pin;
    let callback_context = callbacks.context as usize;
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);
    let peer = tokio::select! {
        outcome = host.accept(&mut pairing_record, move |pin| async move {
            if let Some(callback) = pin_callback
                && let Ok(pin) = CString::new(pin)
            {
                callback(callback_context as *mut c_void, pin.as_ptr());
            }
        }) => outcome.map_err(|_| StageError::new(FailureStage::PairingHost, "The iPhone could not finish pairing."))?,
        _ = wait_for_cancellation(Arc::clone(&cancellation)) => {
            return Err(StageError::new(FailureStage::Cancelled, "Pairing cancelled."));
        }
    };

    Ok(CompletedPairing {
        pairing_record: pairing_record.to_bytes(),
        device_name: peer.name,
        device_model: peer.model,
    })
}

#[allow(clippy::too_many_arguments)]
async fn run_location_session(
    pairing_record_bytes: Vec<u8>,
    peer_address: String,
    remote_pairing_port: u16,
    service_identifier: String,
    auth_tag: String,
    coordinates: Arc<Mutex<Coordinates>>,
    started_callback: LocationStartedCallback,
    callback_context: usize,
    cancellation: Arc<AtomicBool>,
) -> Result<(), StageError> {
    if remote_pairing_port == 0 || service_identifier.is_empty() || auth_tag.is_empty() {
        return Err(StageError::new(
            FailureStage::ServiceIdentity,
            "RemotePairing service identity is incomplete.",
        ));
    }

    let mut pairing_file = RpPairingFile::from_bytes(&pairing_record_bytes)
        .map_err(|_| StageError::new(FailureStage::PairingRecord, "Saved pairing record is invalid."))?;
    let alt_irk = pairing_file.alt_irk().ok_or_else(|| {
        StageError::new(FailureStage::PairingRecord, "Saved pairing record has no AltIRK.")
    })?;
    if !PeerDevice::validate_auth_tag(alt_irk, &service_identifier, &auth_tag) {
        return Err(StageError::new(
            FailureStage::ServiceIdentity,
            "Discovered RemotePairing service does not match this pairing record.",
        ));
    }
    check_cancelled(&cancellation)?;

    let peer_ip: IpAddr = peer_address
        .parse()
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Invalid peer address."))?;
    let pairing_address = SocketAddr::new(peer_ip, remote_pairing_port);
    let stream = timeout(SESSION_TIMEOUT, TcpStream::connect(pairing_address))
        .await
        .map_err(|_| StageError::new(FailureStage::PairVerify, "RemotePairing connection timed out."))?
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Could not reach RemotePairing through 10.7.0.1."))?;

    let socket = RpPairingSocket::new(stream);
    let mut remote_pairing = RemotePairingClient::new(socket, DEFAULT_HOST_NAME);
    timeout(SESSION_TIMEOUT, remote_pairing.attempt_pair_verify())
        .await
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Pair verify timed out."))?
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Pair verify failed."))?;
    timeout(SESSION_TIMEOUT, remote_pairing.validate_pairing(&mut pairing_file))
        .await
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Pairing validation timed out."))?
        .map_err(|_| StageError::new(FailureStage::PairVerify, "Saved pairing is no longer valid."))?;
    check_cancelled(&cancellation)?;

    let tunnel_port = timeout(SESSION_TIMEOUT, remote_pairing.create_tcp_listener())
        .await
        .map_err(|_| StageError::new(FailureStage::SecureTunnel, "Secure tunnel listener timed out."))?
        .map_err(|_| StageError::new(FailureStage::SecureTunnel, "Could not create secure tunnel listener."))?;
    let tunnel_stream = timeout(
        SESSION_TIMEOUT,
        TcpStream::connect(SocketAddr::new(peer_ip, tunnel_port)),
    )
    .await
    .map_err(|_| StageError::new(FailureStage::SecureTunnel, "Secure tunnel connection timed out."))?
    .map_err(|_| StageError::new(FailureStage::SecureTunnel, "Could not connect secure tunnel."))?;
    let tunnel = timeout(
        SESSION_TIMEOUT,
        connect_tls_psk_tunnel_native(tunnel_stream, remote_pairing.encryption_key()),
    )
    .await
    .map_err(|_| StageError::new(FailureStage::SecureTunnel, "TLS-PSK handshake timed out."))?
    .map_err(|_| StageError::new(FailureStage::SecureTunnel, "TLS-PSK handshake failed."))?;

    let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|_| {
        StageError::new(FailureStage::SecureTunnel, "Invalid client tunnel address.")
    })?;
    let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|_| {
        StageError::new(FailureStage::SecureTunnel, "Invalid server tunnel address.")
    })?;
    let rsd_port = tunnel.info.server_rsd_port;
    let adapter = tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    let mut handle = adapter.to_async_handle();

    let rsd_stream = timeout(SESSION_TIMEOUT, handle.connect(rsd_port))
        .await
        .map_err(|_| StageError::new(FailureStage::Rsd, "RSD connection timed out."))?
        .map_err(|_| StageError::new(FailureStage::Rsd, "Could not connect to RSD."))?;
    let mut handshake = timeout(SESSION_TIMEOUT, RsdHandshake::new(rsd_stream))
        .await
        .map_err(|_| StageError::new(FailureStage::Rsd, "RSD handshake timed out."))?
        .map_err(|_| StageError::new(FailureStage::Rsd, "RSD handshake failed."))?;

    let mut dvt = timeout(
        SESSION_TIMEOUT,
        RemoteServerClient::connect_rsd(&mut handle, &mut handshake),
    )
    .await
    .map_err(|_| StageError::new(FailureStage::Dvt, "DVT connection timed out."))?
    .map_err(|_| StageError::new(FailureStage::Dvt, "Could not connect DVT RemoteServer."))?;
    timeout(SESSION_TIMEOUT, dvt.read_message(0))
        .await
        .map_err(|_| StageError::new(FailureStage::Dvt, "DVT readiness timed out."))?
        .map_err(|_| StageError::new(FailureStage::Dvt, "DVT did not become ready."))?;
    let mut location = timeout(SESSION_TIMEOUT, LocationSimulationClient::new(&mut dvt))
        .await
        .map_err(|_| StageError::new(FailureStage::LocationSimulation, "LocationSimulation open timed out."))?
        .map_err(|_| StageError::new(FailureStage::LocationSimulation, "Could not open LocationSimulation."))?;

    let mut applied = current_coordinates(&coordinates)?;
    location
        .set(applied.latitude, applied.longitude)
        .await
        .map_err(|_| StageError::new(FailureStage::LocationSimulation, "The iPhone rejected simulated location."))?;
    if let Some(callback) = started_callback {
        callback(callback_context as *mut c_void);
    }

    let mut last_refresh = Instant::now();
    while !cancellation.load(Ordering::Acquire) {
        sleep(Duration::from_millis(200)).await;
        if cancellation.load(Ordering::Acquire) {
            break;
        }
        let latest = current_coordinates(&coordinates)?;
        if latest != applied || last_refresh.elapsed() >= Duration::from_secs(4) {
            location
                .set(latest.latitude, latest.longitude)
                .await
                .map_err(|_| StageError::new(FailureStage::LocationSimulation, "Active location session ended."))?;
            applied = latest;
            last_refresh = Instant::now();
        }
    }

    timeout(SESSION_TIMEOUT, location.clear())
        .await
        .map_err(|_| StageError::new(FailureStage::Clear, "Location clear timed out."))?
        .map_err(|_| StageError::new(FailureStage::Clear, "Location clear failed."))?;
    Ok(())
}

fn current_coordinates(coordinates: &Arc<Mutex<Coordinates>>) -> Result<Coordinates, StageError> {
    let current = coordinates
        .lock()
        .map_err(|_| StageError::new(FailureStage::Internal, "Coordinate state lock failed."))?;
    Coordinates::validated(current.latitude, current.longitude)
}

fn check_cancelled(cancelled: &Arc<AtomicBool>) -> Result<(), StageError> {
    if cancelled.load(Ordering::Acquire) {
        Err(StageError::new(FailureStage::Cancelled, "Operation cancelled."))
    } else {
        Ok(())
    }
}

async fn wait_for_cancellation(cancelled: Arc<AtomicBool>) {
    while !cancelled.load(Ordering::Acquire) {
        sleep(Duration::from_millis(150)).await;
    }
}

fn publish_ready_callback(
    callbacks: &CallbackSet,
    service_identifier: &str,
    port: u16,
    host_info: &PairableHostInfo,
) {
    let Some(callback) = callbacks.ready else { return };
    let Ok(service_identifier) = CString::new(service_identifier) else { return };
    let records = host_info.mdns_txt_records(service_identifier.to_str().unwrap_or_default());
    let mut keys = Vec::with_capacity(records.len());
    let mut values = Vec::with_capacity(records.len());
    for (key, value) in records {
        let Ok(key) = CString::new(key) else { return };
        let Ok(value) = CString::new(value) else { return };
        keys.push(key);
        values.push(value);
    }
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|value| value.as_ptr()).collect();
    let value_ptrs: Vec<*const c_char> = values.iter().map(|value| value.as_ptr()).collect();
    callback(
        callbacks.context,
        service_identifier.as_ptr(),
        port,
        key_ptrs.as_ptr(),
        value_ptrs.as_ptr(),
        key_ptrs.len(),
    );
}

unsafe fn optional_c_string(value: *const c_char, fallback: &str) -> String {
    if value.is_null() {
        return fallback.to_string();
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

fn owned_c_string(value: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(value).unwrap_or_default().into_raw()
}

fn owned_byte_buffer(value: Vec<u8>) -> (*mut u8, usize) {
    let mut value = value.into_boxed_slice();
    let length = value.len();
    let pointer = value.as_mut_ptr();
    std::mem::forget(value);
    (pointer, length)
}

unsafe fn destroy_byte_buffer(pointer: *mut u8, length: usize) {
    if !pointer.is_null() && length > 0 {
        unsafe { ptr::write_bytes(pointer, 0, length) };
        let slice = ptr::slice_from_raw_parts_mut(pointer, length);
        unsafe { drop(Box::from_raw(slice)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinate_validation_accepts_normal_values() {
        assert_eq!(wloc_coredevice_validate_coordinates(34.052235, -118.243683).code, 0);
    }

    #[test]
    fn coordinate_validation_rejects_invalid_values() {
        let status = wloc_coredevice_validate_coordinates(91.0, 0.0);
        assert_eq!(status.code, 1);
        assert_eq!(status.failure_stage, FailureStage::LocationSimulation as u32);
    }

    #[test]
    fn failure_stage_values_are_stable_for_swift() {
        assert_eq!(FailureStage::PairVerify as u32, 3);
        assert_eq!(FailureStage::SecureTunnel as u32, 4);
        assert_eq!(FailureStage::Rsd as u32, 5);
        assert_eq!(FailureStage::Dvt as u32, 6);
    }
}
