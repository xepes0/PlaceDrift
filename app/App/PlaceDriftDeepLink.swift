import Foundation

extension Notification.Name {
    static let placeDriftSetLocation = Notification.Name("placedrift.setLocation")
}

enum PlaceDriftDeepLinkHandler {
    @MainActor
    static func handle(_ url: URL, controller: CoreDeviceController) {
        guard url.scheme?.lowercased() == "placedrift" else { return }

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
                name: .placeDriftSetLocation,
                object: nil,
                userInfo: ["latitude": latitude, "longitude": longitude]
            )
            controller.setLocation(latitude: latitude, longitude: longitude)

        case "clear":
            controller.clearLocation()

        case "pair":
            guard !controller.hasPairingRecord else { return }
            controller.startPairing()

        default:
            break
        }
    }
}
