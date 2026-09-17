import SwiftUI

struct PlaceDriftAppView: View {
    @ObservedObject var controller: CoreDeviceController
    @StateObject private var transportMonitor = TransportHealthMonitor()
    @StateObject private var permissionRequester = InitialPermissionRequester()
    @StateObject private var mapRegionController = MapRegionController()

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
                    LabeledContent("Transport") {
                        Label(
                            NSLocalizedString(transportStateText, comment: "TUN loopback transport state"),
                            systemImage: transportStateIcon
                        )
                        .foregroundStyle(transportStateColor)
                    }

                    if controller.isLocationActive {
                        Label("LocationSimulation active", systemImage: "location.fill")
                    }

                    if let error = controller.lastError {
                        Text(NSLocalizedString(error, comment: "CoreDevice runtime error"))
                            .foregroundStyle(.red)
                            .font(.footnote)
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

                    Text("Map sharing updates these coordinates automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Pair this iPhone") {
                    if controller.hasPairingRecord {
                        Label("This iPhone is paired", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        Button("Delete Saved Pairing", role: .destructive) {
                            controller.resetPairing()
                        }
                        .disabled(controller.isLocationActive)

                        Text("To pair again, delete the saved pairing record first. This prevents accidentally starting a new pairing session while the current pairing is still valid.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
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

                        Text("After tapping Start Pairing, open Settings › Privacy & Security › Developer Mode › Pair with Host, select PlaceDrift, then enter the PIN shown here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                        Label("Ready for map sharing", systemImage: "square.and.arrow.up.fill")
                            .foregroundStyle(.green)
                    }

                    Text("Share a place from Apple Maps, Amap, or Baidu Maps to PlaceDrift. The shared location is sent directly to the running CoreDevice session; Shortcuts are not required.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if controller.backgroundKeepAliveState == .needsAlwaysAuthorization {
                        Text("To keep PlaceDrift available in the background without the blue location pill, set Location access for PlaceDrift to Always in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Shortcuts") {
                    Text("Build 11 adds a new one-field coordinate action to avoid the cached two-parameter Shortcuts schema. Pass one value such as 22.293882,114.174130.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Map region (experimental)") {
                    LabeledContent("GeoServices country", value: mapRegionController.currentCountryCode)
                    LabeledContent("Region layer", value: NSLocalizedString(mapRegionController.status, comment: "Map region experimental status"))

                    Button("Apply US GeoServices region") {
                        mapRegionController.applyUSRegion()
                    }

                    Button("Restore saved GeoServices region", role: .destructive) {
                        mapRegionController.restoreSavedRegion()
                    }

                    if let error = mapRegionController.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }

                    Text("This layer is separate from DVT LocationSimulation. It writes GeoServices' DeviceCountryCodeSourced value and posts the country-change notification used by Maps. It is experimental: the screen reports the read-back value so we can tell whether iOS accepted the region change before judging the Apple Maps provider switch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Runtime requirement") {
                    Text("Enable loopback-address 10.7.0.1 in the active TUN configuration. Tested working: LocalDevVPN, Clash Mi, Clash, and Karing. Loon and Surge currently fail the RemotePairing protocol check in the tested configurations; Egern is pending verification. PlaceDrift does not start a VPN.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Version", value: versionText)
                }
            }
            .navigationTitle("PlaceDrift")
        }
        .onAppear {
            controller.refreshPairingState()
            transportMonitor.refresh()
            mapRegionController.refresh()
            permissionRequester.requestIfNeeded()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                transportMonitor.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .placeDriftSetLocation)) { note in
            guard
                let latitude = note.userInfo?["latitude"] as? Double,
                let longitude = note.userInfo?["longitude"] as? Double
            else { return }

            self.latitude = String(latitude)
            self.longitude = String(longitude)
            transportMonitor.refresh()
        }
    }

    private var transportStateText: String {
        switch transportMonitor.state {
        case .unknown:
            return "Not checked · 10.7.0.1"
        case .checking:
            return "Checking… · 10.7.0.1"
        case .connected:
            return "Connected · 10.7.0.1"
        case .disconnected:
            return "Not connected · 10.7.0.1"
        case .noRemotePairingService:
            return "RemotePairing not found"
        }
    }

    private var transportStateIcon: String {
        switch transportMonitor.state {
        case .unknown:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected, .noRemotePairingService:
            return "xmark.circle.fill"
        }
    }

    private var transportStateColor: Color {
        switch transportMonitor.state {
        case .connected:
            return .green
        case .checking:
            return .orange
        case .disconnected, .noRemotePairingService:
            return .red
        case .unknown:
            return .secondary
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
        transportMonitor.refresh()
    }
}
