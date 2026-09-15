import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vpn: ProbeVPNController

    var body: some View {
        NavigationStack {
            Form {
                Section("Transport") {
                    LabeledContent("VPN profile", value: vpn.isInstalled ? "Installed" : "Missing")
                    LabeledContent("Tunnel", value: vpn.statusText)
                }

                Section {
                    Button("Install VPN profile") {
                        Task { await vpn.install() }
                    }

                    Button("Start 10.7.0.1 probe") {
                        Task { await vpn.start() }
                    }
                    .disabled(!vpn.isInstalled || vpn.isRunning)

                    Button("Stop probe", role: .destructive) {
                        vpn.stop()
                    }
                    .disabled(!vpn.isRunning)
                }

                Section("What this build does") {
                    Text("Only 10.7.0.1/32 is routed into the PacketTunnel. Normal Internet traffic is not routed through this test tunnel.")
                    Text("The embedded Mihomo core receives loopback-address: 10.7.0.1. This app does not simulate location yet; it only validates the LocalDevVPN-style self-device transport.")
                }

                if let error = vpn.lastError {
                    Section("Error") {
                        Text(error)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("WLOC Transport Probe")
            .refreshable { await vpn.reload() }
        }
    }
}
