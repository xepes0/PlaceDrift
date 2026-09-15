#![allow(dead_code)]

use idevice::ReadWrite;
use idevice::RsdService;
use idevice::dvt::{
    location_simulation::LocationSimulationClient,
    remote_server::RemoteServerClient,
};
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile};
use idevice::rsd::RsdHandshake;

pub fn wasm_api_surface_marker() -> usize {
    // This crate intentionally has no socket implementation yet. The purpose of
    // this target is to prove that the exact idevice revision and CoreDevice
    // protocol surface compile for wasm32-unknown-unknown without native TCP.
    core::mem::size_of::<RpPairingFile>()
}

fn _require_transport<T: ReadWrite>(_transport: &T) {}
fn _require_rsd<T: RsdService>() {}

fn _type_surface<T: ReadWrite>() {
    let _ = core::mem::size_of::<Option<RemotePairingClient<T>>>();
    let _ = core::mem::size_of::<Option<RemoteServerClient<T>>>();
    let _ = core::mem::size_of::<Option<LocationSimulationClient<'static, T>>>();
    let _ = core::mem::size_of::<Option<RsdHandshake<T>>>();
}
