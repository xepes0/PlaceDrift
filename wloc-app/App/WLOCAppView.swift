import SwiftUI

struct WLOCAppView: View {
    @ObservedObject var controller: CoreDeviceProbeController

    @State private var latitude = "34.052235"
    @State private var longitude = "-118.243683"

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
                    if controller.isLocationActive {
                        Label("LocationSimulation active", systemImage: "location.fill")
                    }
                    if let error = controller.lastError {
                        Text(error)
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

                    Text("After tapping Start Pairing, open Settings › Privacy & Security › Developer Mode › Pair with Host, select WLOC, then enter the PIN shown here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                }

                Section("Runtime requirement") {
                    Text("Keep Clash Mi connected with TUN loopback-address 10.7.0.1. WLOC does not start a VPN.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("WLOC")
        }
        .onAppear {
            controller.refreshPairingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wlocDeepLinkSetLocation)) { note in
            guard
                let latitude = note.userInfo?["latitude"] as? Double,
                let longitude = note.userInfo?["longitude"] as? Double
            else { return }
            self.latitude = String(latitude)
            self.longitude = String(longitude)
        }
    }

    private func setLocationFromFields() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        controller.setLocation(latitude: lat, longitude: lon)
    }
}
