import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var probe: CoreDeviceProbeController
    @State private var latitude = "34.052235"
    @State private var longitude = "-118.243683"
    @State private var showingPairingExporter = false
    @State private var pairingDocument = PairingRecordDocument()
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Clash Mi prerequisite") {
                    Text("Keep Clash Mi 1.0.28.1406 connected with TUN stack mixed and loopback-address 10.7.0.1. This app does not start a VPN.")
                    LabeledContent("Pairing record", value: probe.hasPairingRecord ? "Saved" : "Missing")
                    LabeledContent("Engine", value: probe.status)
                    if probe.lastFailureStage != "None" {
                        LabeledContent("Failure stage", value: probe.lastFailureStage)
                    }
                }

                Section("1 · Pair this iPhone") {
                    Button(probe.isPairing ? "Pairing…" : "Start Pairing") {
                        probe.startPairing()
                    }
                    .disabled(probe.isPairing || probe.isLocationActive)

                    if probe.isPairing {
                        Button("Cancel Pairing", role: .destructive) {
                            probe.cancelPairing()
                        }
                    }

                    if let pin = probe.pairingPIN {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pair with Host PIN")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(pin)
                                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    Text("After tapping Start Pairing, open Settings › Privacy & Security › Developer Mode › Pair with Host, select WLOC CoreDevice Probe, then enter the PIN shown here.")
                        .font(.footnote)

                    if probe.hasPairingRecord {
                        Button("Export pairing record for Browser PoC") {
                            if let data = PairingRecordExporter.load(), !data.isEmpty {
                                pairingDocument = PairingRecordDocument(data: data)
                                exportError = nil
                                showingPairingExporter = true
                            } else {
                                exportError = "Could not read the saved pairing record from Keychain."
                            }
                        }
                        .disabled(probe.isPairing || probe.isLocationActive)

                        Text("Treat this exported file as a device credential. Save it locally and do not upload it to GitHub, Cloudflare, chat, or any public service.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Delete saved pairing", role: .destructive) {
                            probe.resetPairing()
                        }
                        .disabled(probe.isPairing || probe.isLocationActive)
                    }
                }

                Section("2 · LocationSimulation") {
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)

                    Button(probe.isLocationActive ? "Update Location" : "Set Location") {
                        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
                        probe.setLocation(latitude: lat, longitude: lon)
                    }
                    .disabled(!probe.hasPairingRecord || probe.isPairing || probe.isDiscovering)

                    Button("Clear / Restore Real Location", role: .destructive) {
                        probe.clearLocation()
                    }
                    .disabled(!probe.isLocationActive && !probe.isDiscovering)

                    if probe.isDiscovering {
                        ProgressView("Discovering _remotepairing._tcp…")
                    }
                }

                if let exportError {
                    Section("Pairing export") {
                        Text(exportError)
                    }
                }

                if let error = probe.lastError {
                    Section("Diagnostic") {
                        Text(error)
                            .textSelection(.enabled)
                    }
                }

                Section("First test") {
                    Text("Use the default Los Angeles coordinate. Once the status says LocationSimulation active, switch to Apple Maps within about 20 seconds and check whether the blue dot moves. Return here and tap Clear afterwards.")
                }
            }
            .navigationTitle("WLOC CoreDevice Probe")
            .onAppear { probe.refreshPairingState() }
            .fileExporter(
                isPresented: $showingPairingExporter,
                document: pairingDocument,
                contentType: .data,
                defaultFilename: "WLOC-RPPairing.rppairing"
            ) { result in
                if case .failure(let error) = result {
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
