import SwiftUI

struct PlaceDriftAppView: View {
    @ObservedObject var controller: CoreDeviceController

    @State private var latitude = "34.052235"
    @State private var longitude = "-118.243683"

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent(
                        "Pairing",
                        value: controller.hasPairingRecord
                            ? NSLocalizedString("Saved", comment: "Saved pairing state")
                            : NSLocalizedString("Not paired", comment: "Missing pairing state")
                    )
                    LabeledContent(
                        "Engine",
                        value: NSLocalizedString(controller.status, comment: "CoreDevice engine status")
                    )
                    LabeledContent("Transport", value: "10.7.0.1")
                    LabeledContent("Version", value: versionText)

                    if controller.isLocationActive {
                        Label("LocationSimulation active", systemImage: "location.fill")
                    }

                    if let error = controller.lastError {
                        Text(NSLocalizedString(error, comment: "CoreDevice runtime error"))
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section("Pair this iPhone") {
                    if let pin = controller.pairingPIN {
                        LabeledContent("Pair with Host PIN", value: pin)
                            .font(.title3.monospacedDigit())
                    }

                    Button(
                        controller.isPairing
                            ? NSLocalizedString("Pairing…", comment: "Pairing button busy state")
                            : NSLocalizedString("Start Pairing", comment: "Pairing button")
                    ) {
                        controller.startPairing()
                    }
                    .disabled(controller.isPairing || controller.isLocationActive)

                    if controller.isPairing {
                        Button("Cancel Pairing", role: .destructive) {
                            controller.cancelPairing()
                        }
                    }

                    if controller.hasPairingRecord {
                        Button("Delete Saved Pairing", role: .destructive) {
                            controller.resetPairing()
                        }
                        .disabled(controller.isLocationActive)
                    }

                    Text("After tapping Start Pairing, open Settings › Privacy & Security › Developer Mode › Pair with Host, select PlaceDrift, then enter the PIN shown here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Maps sharing") {
                    Toggle(
                        "Enable Maps sharing",
                        isOn: Binding(
                            get: { controller.isMapSharingEnabled },
                            set: { controller.setMapSharingEnabled($0) }
                        )
                    )
                    .disabled(!controller.hasPairingRecord)

                    LabeledContent(
                        "Share receiver",
                        value: controller.shareBridgeReady
                            ? NSLocalizedString("Listening", comment: "Share bridge ready state")
                            : NSLocalizedString("Stopped", comment: "Share bridge stopped state")
                    )

                    LabeledContent(
                        "Background",
                        value: NSLocalizedString(backgroundStateText, comment: "Background keepalive state")
                    )

                    if controller.mapSharingReady {
                        Label("Ready for Apple Maps sharing", systemImage: "square.and.arrow.up.fill")
                            .foregroundStyle(.green)
                    }

                    Text("In Apple Maps, choose a place, tap Share, then choose PlaceDrift. The shared location is sent directly to the running CoreDevice session; Shortcuts are not required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if controller.backgroundKeepAliveState == .needsAlwaysAuthorization {
                        Text("To keep PlaceDrift available in the background without the blue location pill, set Location access for PlaceDrift to Always in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Location") {
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)

                    Button(
                        controller.isLocationActive
                            ? NSLocalizedString("Update Location", comment: "Update simulated location")
                            : NSLocalizedString("Set Location", comment: "Set simulated location")
                    ) {
                        setLocationFromFields()
                    }
                    .disabled(!controller.canStartLocation && !controller.isLocationActive)

                    Button("Restore Real Location", role: .destructive) {
                        controller.clearLocation()
                    }
                    .disabled(!controller.isLocationActive && !controller.isDiscovering)

                    Text("Apple Maps sharing updates these coordinates automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Shortcuts") {
                    Text("You can pass a Shortcuts Location directly to PlaceDrift, pass latitude and longitude, or restore the real location.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Runtime requirement") {
                    Text("Enable loopback-address 10.7.0.1 in the active TUN configuration. Tested working: LocalDevVPN, Clash Mi, and Clash. Surge, Egern, and other VPN/TUN apps are pending verification. PlaceDrift does not start a VPN.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PlaceDrift")
        }
        .onAppear {
            controller.refreshPairingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .placeDriftSetLocation)) { note in
            guard
                let latitude = note.userInfo?["latitude"] as? Double,
                let longitude = note.userInfo?["longitude"] as? Double
            else { return }

            self.latitude = String(latitude)
            self.longitude = String(longitude)
        }
    }

    private var backgroundStateText: String {
        switch controller.backgroundKeepAliveState {
        case .idle, .stopped:
            return "Stopped"
        case .requestingAlwaysAuthorization:
            return "Requesting Always Location…"
        case .needsAlwaysAuthorization:
            return "Needs Always Location"
        case .active:
            return "Active"
        case .denied:
            return "Location permission denied"
        case .restricted:
            return "Location permission restricted"
        case .servicesDisabled:
            return "Location Services disabled"
        case .failed:
            return "Background keep-alive failed"
        }
    }

    private func setLocationFromFields() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        controller.setLocation(latitude: lat, longitude: lon)
    }
}
