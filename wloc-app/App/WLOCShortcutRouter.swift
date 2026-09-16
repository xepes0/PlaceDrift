import Foundation

private enum WLOCShortcutCommand: Codable {
    case setLocation(latitude: Double, longitude: Double)
    case clearLocation
    case startPairing
}

@MainActor
enum WLOCShortcutRouter {
    private static let pendingCommandKey = "wloc.shortcut.pending-command"
    private static var controller: CoreDeviceProbeController?

    static func attach(_ controller: CoreDeviceProbeController) {
        self.controller = controller
        consumePendingCommand()
    }

    static func setLocation(latitude: Double, longitude: Double) {
        submit(.setLocation(latitude: latitude, longitude: longitude))
    }

    static func clearLocation() {
        submit(.clearLocation)
    }

    static func startPairing() {
        submit(.startPairing)
    }

    private static func submit(_ command: WLOCShortcutCommand) {
        guard let controller else {
            savePendingCommand(command)
            return
        }
        apply(command, to: controller)
    }

    private static func consumePendingCommand() {
        guard
            let data = UserDefaults.standard.data(forKey: pendingCommandKey),
            let command = try? JSONDecoder().decode(WLOCShortcutCommand.self, from: data),
            let controller
        else { return }

        UserDefaults.standard.removeObject(forKey: pendingCommandKey)
        apply(command, to: controller)
    }

    private static func savePendingCommand(_ command: WLOCShortcutCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        UserDefaults.standard.set(data, forKey: pendingCommandKey)
    }

    private static func apply(_ command: WLOCShortcutCommand, to controller: CoreDeviceProbeController) {
        switch command {
        case .setLocation(let latitude, let longitude):
            NotificationCenter.default.post(
                name: .wlocDeepLinkSetLocation,
                object: nil,
                userInfo: ["latitude": latitude, "longitude": longitude]
            )
            controller.setLocation(latitude: latitude, longitude: longitude)

        case .clearLocation:
            controller.clearLocation()

        case .startPairing:
            controller.startPairing()
        }
    }
}
