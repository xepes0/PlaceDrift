import SwiftUI

@main
struct WLOCCoreDeviceProbeApp: App {
    @StateObject private var probe = CoreDeviceProbeController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(probe)
        }
    }
}
