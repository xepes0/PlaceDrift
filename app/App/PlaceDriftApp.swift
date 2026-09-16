import SwiftUI

@main
struct PlaceDriftApp: App {
    @StateObject private var controller = CoreDeviceController()

    var body: some Scene {
        WindowGroup {
            PlaceDriftAppView(controller: controller)
                .onOpenURL { url in
                    PlaceDriftDeepLinkHandler.handle(url, controller: controller)
                }
        }
    }
}
