import SwiftUI

@main
struct WLOCApp: App {
    @StateObject private var controller = CoreDeviceProbeController()

    var body: some Scene {
        WindowGroup {
            WLOCAppView(controller: controller)
                .onOpenURL { url in
                    WLOCDeepLinkHandler.handle(url, controller: controller)
                }
        }
    }
}
