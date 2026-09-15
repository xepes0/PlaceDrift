use idevice::dvt::{
    location_simulation::LocationSimulationClient,
    remote_server::RemoteServerClient,
};
use idevice::remote_pairing::{
    PeerDevice, RemotePairingClient, RpPairingFile, RpPairingSocket,
    connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp;

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

#[unsafe(no_mangle)]
pub extern "C" fn wloc_coredevice_validate_coordinates(latitude: f64, longitude: f64) -> EngineStatus {
    if latitude.is_finite()
        && longitude.is_finite()
        && (-90.0..=90.0).contains(&latitude)
        && (-180.0..=180.0).contains(&longitude)
    {
        EngineStatus::ok()
    } else {
        EngineStatus::failed(FailureStage::LocationSimulation)
    }
}

/// Compile-time API surface probe.
///
/// The real session implementation will be added after the transport PoC is
/// stable. Keeping these imports in the crate makes CI fail immediately if the
/// pinned `idevice` revision no longer exposes the exact CoreDevice pieces we
/// intend to use.
#[allow(dead_code)]
fn api_surface_probe() {
    let _ = core::mem::size_of::<Option<LocationSimulationClient<'static>>>();
    let _ = core::mem::size_of::<Option<RemoteServerClient>>();
    let _ = core::mem::size_of::<Option<RpPairingFile>>();
    let _ = core::mem::size_of::<Option<RpPairingSocket<tokio::net::TcpStream>>>();

    let _ = PeerDevice::validate_auth_tag;
    let _ = RemotePairingClient::<RpPairingSocket<tokio::net::TcpStream>>::new;
    let _ = connect_tls_psk_tunnel_native::<tokio::net::TcpStream>;
    let _ = RsdHandshake::new;
    let _ = tcp::adapter::Adapter::new;
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
}
