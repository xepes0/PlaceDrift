import Foundation

extension Notification.Name {
    static let wlocDeepLinkSetLocation = Notification.Name("wloc.deepLink.setLocation")
}

enum WLOCDeepLinkHandler {
    @MainActor
    static func handle(_ url: URL, controller: CoreDeviceProbeController) {
        guard url.scheme?.lowercased() == "wloc" else { return }

        switch url.host?.lowercased() {
        case "set":
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let latString = components.queryItems?.first(where: { $0.name == "lat" })?.value,
                let lonString = components.queryItems?.first(where: { $0.name == "lon" })?.value,
                let latitude = Double(latString),
                let longitude = Double(lonString)
            else { return }

            NotificationCenter.default.post(
                name: .wlocDeepLinkSetLocation,
                object: nil,
                userInfo: ["latitude": latitude, "longitude": longitude]
            )
            controller.setLocation(latitude: latitude, longitude: longitude)

        case "clear":
            controller.clearLocation()

        case "pair":
            controller.startPairing()

        default:
            break
        }
    }
}
