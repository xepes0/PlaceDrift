import Foundation

private enum PlaceDriftShortcutCommand: Codable {
    case setLocation(latitude: Double, longitude: Double)
    case clearLocation
    case startPairing
}

@MainActor
enum PlaceDriftShortcutRouter {
    private static let pendingCommandKey = "placedrift.shortcut.pending-command"
    private static var controller: CoreDeviceController?

    static func attach(_ controller: CoreDeviceController) {
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

    private static func submit(_ command: PlaceDriftShortcutCommand) {
        guard let controller else {
            savePendingCommand(command)
            return
        }
        apply(command, to: controller)
    }

    private static func consumePendingCommand() {
        guard
            let data = UserDefaults.standard.data(forKey: pendingCommandKey),
            let command = try? JSONDecoder().decode(PlaceDriftShortcutCommand.self, from: data),
            let controller
        else { return }

        UserDefaults.standard.removeObject(forKey: pendingCommandKey)
        apply(command, to: controller)
    }

    private static func savePendingCommand(_ command: PlaceDriftShortcutCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        UserDefaults.standard.set(data, forKey: pendingCommandKey)
    }

    private static func apply(_ command: PlaceDriftShortcutCommand, to controller: CoreDeviceController) {
        switch command {
        case .setLocation(let latitude, let longitude):
            NotificationCenter.default.post(
                name: .placeDriftSetLocation,
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
