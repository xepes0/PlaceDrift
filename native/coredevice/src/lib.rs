use std::{
    ffi::{CStr, CString, c_char, c_void},
    net::{IpAddr, Ipv4Addr, SocketAddr},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
    time::Duration,
};
use idevice::{
    RsdService, tcp,
    dvt::{location_simulation::LocationSimulationClient, remote_server::RemoteServerClient},
    remote_pairing::{PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
};
use tokio::{
    net::{TcpListener, TcpStream},
    time::{Instant, sleep, timeout},
};

const HOST: &str = "PlaceDrift";
const MODEL: &str = "Mac17,7";
const PEER: &str = "10.7.0.1";
const T: Duration = Duration::from_secs(15);

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FailureStage { None=0, PairingRecord=1, ServiceIdentity=2, PairVerify=3, SecureTunnel=4, Rsd=5, Dvt=6, LocationSimulation=7, Clear=8, PairingHost=9, Cancelled=10, Internal=255 }

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct EngineStatus { pub code:i32, pub failure_stage:u32 }
impl EngineStatus {
    fn ok()->Self { Self{code:0,failure_stage:0} }
    fn err(s:FailureStage)->Self { Self{code:1,failure_stage:s as u32} }
}
#[derive(Debug)]
struct StageError { stage:FailureStage, message:String }
impl StageError { fn new(stage:FailureStage, message:impl Into<String>)->Self { Self{stage,message:message.into()} } }

#[derive(Clone, Copy, PartialEq)]
struct Coordinates { latitude:f64, longitude:f64 }
impl Coordinates {
    fn new(latitude:f64,longitude:f64)->Result<Self,StageError>{
        if latitude.is_finite()&&longitude.is_finite()&&(-90.0..=90.0).contains(&latitude)&&(-180.0..=180.0).contains(&longitude){
            Ok(Self{latitude,longitude})
        } else { Err(StageError::new(FailureStage::LocationSimulation,"Coordinates are outside the valid range.")) }
    }
}

pub type PairingReadyCallback=Option<extern "C" fn(*mut c_void,*const c_char,u16,*const *const c_char,*const *const c_char,usize)>;
pub type PairingPinCallback=Option<extern "C" fn(*mut c_void,*const c_char)>;
pub type LocationStartedCallback=Option<extern "C" fn(*mut c_void)>;

#[repr(C)] pub struct PairingSession { cancelled:Arc<AtomicBool> }
#[repr(C)] pub struct LocationSession { cancelled:Arc<AtomicBool>, coordinates:Arc<Mutex<Coordinates>> }
#[repr(C)] pub struct PairingResult { pub error_message:*mut c_char,pub failure_stage:u32,pub pairing_record:*mut u8,pub pairing_record_length:usize,pub device_name:*mut c_char,pub device_model:*mut c_char }
#[repr(C)] pub struct LocationResult { pub error_message:*mut c_char,pub failure_stage:u32 }

impl PairingResult { fn empty()->Self{Self{error_message:ptr::null_mut(),failure_stage:0,pairing_record:ptr::null_mut(),pairing_record_length:0,device_name:ptr::null_mut(),device_model:ptr::null_mut()}} }
impl LocationResult { fn empty()->Self{Self{error_message:ptr::null_mut(),failure_stage:0}} }

struct Callbacks { ready:PairingReadyCallback,pin:PairingPinCallback,context:*mut c_void }
unsafe impl Send for Callbacks {}
struct CompletedPairing { record:Vec<u8>, name:String, model:String }

#[unsafe(no_mangle)]
pub extern "C" fn placedrift_coredevice_validate_coordinates(lat:f64,lon:f64)->EngineStatus{
    match Coordinates::new(lat,lon){Ok(_)=>EngineStatus::ok(),Err(e)=>EngineStatus::err(e.stage)}
}
#[unsafe(no_mangle)]
pub extern "C" fn placedrift_pairing_session_create()->*mut PairingSession{Box::into_raw(Box::new(PairingSession{cancelled:Arc::new(AtomicBool::new(false))}))}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_pairing_session_cancel(p:*mut PairingSession){if let Some(s)=unsafe{p.as_ref()}{s.cancelled.store(true,Ordering::Release)}}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_pairing_session_destroy(p:*mut PairingSession){if !p.is_null(){unsafe{drop(Box::from_raw(p))}}}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_pairing_session_run(s:*mut PairingSession,ready:PairingReadyCallback,pin:PairingPinCallback,ctx:*mut c_void,out:*mut PairingResult)->i32{
    if s.is_null()||out.is_null(){return 2}
    unsafe{*out=PairingResult::empty()}; let s=unsafe{&*s}; s.cancelled.store(false,Ordering::Release);
    let c=Arc::clone(&s.cancelled); let cb=Callbacks{ready,pin,context:ctx};
    let r=catch_unwind(AssertUnwindSafe(||tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|_|StageError::new(FailureStage::Internal,"Could not start pairing runtime.")).and_then(|rt|rt.block_on(run_pairing(cb,c)))));
    match r{
        Ok(Ok(v))=>{let (p,n)=own_bytes(v.record);unsafe{(*out).pairing_record=p;(*out).pairing_record_length=n;(*out).device_name=own_string(v.name);(*out).device_model=own_string(v.model)};0}
        Ok(Err(e))=>{unsafe{(*out).failure_stage=e.stage as u32;(*out).error_message=own_string(e.message)};1}
        Err(_)=>{unsafe{(*out).failure_stage=FailureStage::Internal as u32;(*out).error_message=own_string("Pairing engine stopped unexpectedly.")};1}
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_pairing_result_destroy(p:*mut PairingResult){
    let Some(r)=unsafe{p.as_mut()}else{return};
    for v in [r.error_message,r.device_name,r.device_model]{if !v.is_null(){unsafe{drop(CString::from_raw(v))}}}
    unsafe{drop_bytes(r.pairing_record,r.pairing_record_length)};*r=PairingResult::empty();
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_pairing_record_matches_service(record:*const u8,len:usize,id:*const c_char,tag:*const c_char)->i32{
    if record.is_null()||len==0||id.is_null()||tag.is_null(){return 0}
    let ok=catch_unwind(AssertUnwindSafe(||{
        let b=unsafe{std::slice::from_raw_parts(record,len)};
        let Ok(f)=RpPairingFile::from_bytes(b)else{return false};
        let Some(k)=f.alt_irk()else{return false};
        let Ok(i)=unsafe{CStr::from_ptr(id)}.to_str()else{return false};
        let Ok(t)=unsafe{CStr::from_ptr(tag)}.to_str()else{return false};
        PeerDevice::validate_auth_tag(k,i.trim(),t.trim())
    }));
    matches!(ok,Ok(true)) as i32
}

#[unsafe(no_mangle)]
pub extern "C" fn placedrift_location_session_create()->*mut LocationSession{
    Box::into_raw(Box::new(LocationSession{cancelled:Arc::new(AtomicBool::new(false)),coordinates:Arc::new(Mutex::new(Coordinates{latitude:0.0,longitude:0.0}))}))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_location_session_update(p:*mut LocationSession,lat:f64,lon:f64)->i32{
    let Some(s)=unsafe{p.as_ref()}else{return 2};let Ok(v)=Coordinates::new(lat,lon)else{return 1};let Ok(mut c)=s.coordinates.lock()else{return 2};*c=v;0
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_location_session_cancel(p:*mut LocationSession){if let Some(s)=unsafe{p.as_ref()}{s.cancelled.store(true,Ordering::Release)}}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_location_session_destroy(p:*mut LocationSession){if !p.is_null(){unsafe{drop(Box::from_raw(p))}}}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_location_session_run(
    p:*mut LocationSession,record:*const u8,len:usize,peer:*const c_char,port:u16,id:*const c_char,tag:*const c_char,
    lat:f64,lon:f64,started:LocationStartedCallback,ctx:*mut c_void,out:*mut LocationResult
)->i32{
    if p.is_null()||out.is_null()||record.is_null()||len==0||id.is_null()||tag.is_null(){return 2}
    unsafe{*out=LocationResult::empty()};let s=unsafe{&*p};s.cancelled.store(false,Ordering::Release);
    let bytes=unsafe{std::slice::from_raw_parts(record,len)}.to_vec();
    let peer=unsafe{cstr_or(peer,PEER)};let id=unsafe{cstr_or(id,"")};let tag=unsafe{cstr_or(tag,"")};
    let Ok(v)=Coordinates::new(lat,lon)else{unsafe{(*out).failure_stage=FailureStage::LocationSimulation as u32};return 1};
    if let Ok(mut c)=s.coordinates.lock(){*c=v}
    let cancel=Arc::clone(&s.cancelled);let coords=Arc::clone(&s.coordinates);let ctx=ctx as usize;
    let r=catch_unwind(AssertUnwindSafe(||tokio::runtime::Builder::new_multi_thread().worker_threads(3).enable_all().build().map_err(|_|StageError::new(FailureStage::Internal,"Could not start device runtime.")).and_then(|rt|rt.block_on(run_location(bytes,peer,port,id,tag,coords,started,ctx,cancel)))));
    match r{Ok(Ok(()))=>0,Ok(Err(e))=>{unsafe{(*out).failure_stage=e.stage as u32;(*out).error_message=own_string(e.message)};1},Err(_)=>{unsafe{(*out).failure_stage=FailureStage::Internal as u32;(*out).error_message=own_string("Location engine stopped unexpectedly.")};1}}
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn placedrift_location_result_destroy(p:*mut LocationResult){let Some(r)=unsafe{p.as_mut()}else{return};if !r.error_message.is_null(){unsafe{drop(CString::from_raw(r.error_message))}}*r=LocationResult::empty()}

async fn run_pairing(cb:Callbacks,cancel:Arc<AtomicBool>)->Result<CompletedPairing,StageError>{
    check(&cancel)?;
    let listener=TcpListener::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(),0)).await.map_err(|_|StageError::new(FailureStage::PairingHost,"Could not open pairing listener."))?;
    let port=listener.local_addr().map_err(|_|StageError::new(FailureStage::PairingHost,"Could not read pairing port."))?.port();
    let mut record=RpPairingFile::generate(HOST);let info=PairableHostInfo::generate(HOST,MODEL);publish(&cb,&record.identifier,port,&info);
    let (stream,_)=tokio::select!{r=listener.accept()=>r.map_err(|_|StageError::new(FailureStage::PairingHost,"The iPhone did not open the pairing connection."))?,_=wait(Arc::clone(&cancel))=>return Err(StageError::new(FailureStage::Cancelled,"Pairing cancelled."))};
    let pin=cb.pin;let ctx=cb.context as usize;let mut host=PairableHost::new(RpPairingSocket::new_device(stream),info);
    let peer=tokio::select!{
        r=host.accept(&mut record,move|v|async move{if let Some(f)=pin&&let Ok(v)=CString::new(v){f(ctx as *mut c_void,v.as_ptr())}})=>r.map_err(|_|StageError::new(FailureStage::PairingHost,"The iPhone could not finish pairing."))?,
        _=wait(Arc::clone(&cancel))=>return Err(StageError::new(FailureStage::Cancelled,"Pairing cancelled."))
    };
    Ok(CompletedPairing{record:record.to_bytes(),name:peer.name,model:peer.model})
}

#[allow(clippy::too_many_arguments)]
async fn run_location(
    bytes:Vec<u8>,peer:String,port:u16,id:String,tag:String,coords:Arc<Mutex<Coordinates>>,started:LocationStartedCallback,ctx:usize,cancel:Arc<AtomicBool>
)->Result<(),StageError>{
    if port==0||id.is_empty()||tag.is_empty(){return Err(StageError::new(FailureStage::ServiceIdentity,"RemotePairing service identity is incomplete."))}
    let mut file=RpPairingFile::from_bytes(&bytes).map_err(|_|StageError::new(FailureStage::PairingRecord,"Saved pairing record is invalid."))?;
    let key=file.alt_irk().ok_or_else(||StageError::new(FailureStage::PairingRecord,"Saved pairing record has no AltIRK."))?;
    if !PeerDevice::validate_auth_tag(key,&id,&tag){return Err(StageError::new(FailureStage::ServiceIdentity,"RemotePairing service does not match the pairing record."))}
    check(&cancel)?;
    let ip:IpAddr=peer.parse().map_err(|_|StageError::new(FailureStage::PairVerify,"Invalid peer address."))?;
    let stream=timeout(T,TcpStream::connect(SocketAddr::new(ip,port))).await.map_err(|_|StageError::new(FailureStage::PairVerify,"RemotePairing connection timed out."))?.map_err(|_|StageError::new(FailureStage::PairVerify,"Could not reach RemotePairing through 10.7.0.1."))?;
    let mut rp=RemotePairingClient::new(RpPairingSocket::new(stream),HOST);
    timeout(T,rp.attempt_pair_verify()).await.map_err(|_|StageError::new(FailureStage::PairVerify,"Pair verify timed out."))?.map_err(|_|StageError::new(FailureStage::PairVerify,"Pair verify failed."))?;
    timeout(T,rp.validate_pairing(&mut file)).await.map_err(|_|StageError::new(FailureStage::PairVerify,"Pairing validation timed out."))?.map_err(|_|StageError::new(FailureStage::PairVerify,"Saved pairing is no longer valid."))?;
    check(&cancel)?;
    let tunnel_port=timeout(T,rp.create_tcp_listener()).await.map_err(|_|StageError::new(FailureStage::SecureTunnel,"Secure tunnel listener timed out."))?.map_err(|_|StageError::new(FailureStage::SecureTunnel,"Could not create secure tunnel listener."))?;
    let stream=timeout(T,TcpStream::connect(SocketAddr::new(ip,tunnel_port))).await.map_err(|_|StageError::new(FailureStage::SecureTunnel,"Secure tunnel connection timed out."))?.map_err(|_|StageError::new(FailureStage::SecureTunnel,"Could not connect secure tunnel."))?;
    let tunnel=timeout(T,connect_tls_psk_tunnel_native(stream,rp.encryption_key())).await.map_err(|_|StageError::new(FailureStage::SecureTunnel,"TLS-PSK handshake timed out."))?.map_err(|_|StageError::new(FailureStage::SecureTunnel,"TLS-PSK handshake failed."))?;
    let client:IpAddr=tunnel.info.client_address.parse().map_err(|_|StageError::new(FailureStage::SecureTunnel,"Invalid client tunnel address."))?;
    let server:IpAddr=tunnel.info.server_address.parse().map_err(|_|StageError::new(FailureStage::SecureTunnel,"Invalid server tunnel address."))?;
    let rsd_port=tunnel.info.server_rsd_port;let adapter=tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()),client,server);let mut handle=adapter.to_async_handle();
    let rsd=timeout(T,handle.connect(rsd_port)).await.map_err(|_|StageError::new(FailureStage::Rsd,"RSD connection timed out."))?.map_err(|_|StageError::new(FailureStage::Rsd,"Could not connect to RSD."))?;
    let mut handshake=timeout(T,RsdHandshake::new(rsd)).await.map_err(|_|StageError::new(FailureStage::Rsd,"RSD handshake timed out."))?.map_err(|_|StageError::new(FailureStage::Rsd,"RSD handshake failed."))?;
    let mut dvt=timeout(T,RemoteServerClient::connect_rsd(&mut handle,&mut handshake)).await.map_err(|_|StageError::new(FailureStage::Dvt,"DVT connection timed out."))?.map_err(|_|StageError::new(FailureStage::Dvt,"Could not connect DVT RemoteServer."))?;
    timeout(T,dvt.read_message(0)).await.map_err(|_|StageError::new(FailureStage::Dvt,"DVT readiness timed out."))?.map_err(|_|StageError::new(FailureStage::Dvt,"DVT did not become ready."))?;
    let mut location=timeout(T,LocationSimulationClient::new(&mut dvt)).await.map_err(|_|StageError::new(FailureStage::LocationSimulation,"LocationSimulation open timed out."))?.map_err(|_|StageError::new(FailureStage::LocationSimulation,"Could not open LocationSimulation."))?;
    let mut applied=current(&coords)?;location.set(applied.latitude,applied.longitude).await.map_err(|_|StageError::new(FailureStage::LocationSimulation,"The iPhone rejected simulated location."))?;if let Some(f)=started{f(ctx as *mut c_void)}
    let mut refreshed=Instant::now();
    while !cancel.load(Ordering::Acquire){
        sleep(Duration::from_millis(200)).await;if cancel.load(Ordering::Acquire){break}
        let next=current(&coords)?;if next!=applied||refreshed.elapsed()>=Duration::from_secs(4){location.set(next.latitude,next.longitude).await.map_err(|_|StageError::new(FailureStage::LocationSimulation,"Active location session ended."))?;applied=next;refreshed=Instant::now()}
    }
    timeout(T,location.clear()).await.map_err(|_|StageError::new(FailureStage::Clear,"Location clear timed out."))?.map_err(|_|StageError::new(FailureStage::Clear,"Location clear failed."))?;Ok(())
}

fn current(v:&Arc<Mutex<Coordinates>>)->Result<Coordinates,StageError>{let c=v.lock().map_err(|_|StageError::new(FailureStage::Internal,"Coordinate state lock failed."))?;Coordinates::new(c.latitude,c.longitude)}
fn check(v:&Arc<AtomicBool>)->Result<(),StageError>{if v.load(Ordering::Acquire){Err(StageError::new(FailureStage::Cancelled,"Operation cancelled."))}else{Ok(())}}
async fn wait(v:Arc<AtomicBool>){while !v.load(Ordering::Acquire){sleep(Duration::from_millis(150)).await}}
fn publish(cb:&Callbacks,id:&str,port:u16,info:&PairableHostInfo){
    let Some(f)=cb.ready else{return};let Ok(id)=CString::new(id)else{return};let records=info.mdns_txt_records(id.to_str().unwrap_or_default());let mut ks=Vec::new();let mut vs=Vec::new();
    for(k,v)in records{let Ok(k)=CString::new(k)else{return};let Ok(v)=CString::new(v)else{return};ks.push(k);vs.push(v)}
    let kp:Vec<*const c_char>=ks.iter().map(|v|v.as_ptr()).collect();let vp:Vec<*const c_char>=vs.iter().map(|v|v.as_ptr()).collect();f(cb.context,id.as_ptr(),port,kp.as_ptr(),vp.as_ptr(),kp.len())
}
unsafe fn cstr_or(v:*const c_char,fallback:&str)->String{if v.is_null(){return fallback.to_string()}unsafe{CStr::from_ptr(v)}.to_str().ok().map(str::trim).filter(|v|!v.is_empty()).unwrap_or(fallback).to_string()}
fn own_string(v:impl Into<Vec<u8>>)->*mut c_char{CString::new(v).unwrap_or_default().into_raw()}
fn own_bytes(v:Vec<u8>)->(*mut u8,usize){let mut v=v.into_boxed_slice();let n=v.len();let p=v.as_mut_ptr();std::mem::forget(v);(p,n)}
unsafe fn drop_bytes(p:*mut u8,n:usize){if !p.is_null()&&n>0{unsafe{ptr::write_bytes(p,0,n)};let s=ptr::slice_from_raw_parts_mut(p,n);unsafe{drop(Box::from_raw(s))}}}

#[cfg(test)]
mod tests{
    use super::*;
    #[test]fn valid(){assert_eq!(placedrift_coredevice_validate_coordinates(34.0,-118.0).code,0)}
    #[test]fn invalid(){assert_eq!(placedrift_coredevice_validate_coordinates(91.0,0.0).failure_stage,7)}
}
