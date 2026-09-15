import SwiftUI

@main
struct WLOCTransportProbeApp: App {
    @StateObject private var vpn = ProbeVPNController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpn)
                .task { await vpn.reload() }
        }
    }
}
