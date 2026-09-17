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
    private static var pendingRetryTask: Task<Void, Never>?

    static func attach(_ controller: CoreDeviceController) {
        self.controller = controller
        _ = consumePendingCommand()
        schedulePendingCommandRetries()
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

    @discardableResult
    private static func consumePendingCommand() -> Bool {
        guard
            let data = UserDefaults.standard.data(forKey: pendingCommandKey),
            let command = try? JSONDecoder().decode(PlaceDriftShortcutCommand.self, from: data),
            let controller
        else { return false }

        UserDefaults.standard.removeObject(forKey: pendingCommandKey)
        apply(command, to: controller)
        return true
    }

    private static func schedulePendingCommandRetries() {
        pendingRetryTask?.cancel()
        pendingRetryTask = Task { @MainActor in
            // openAppWhenRun can make the main app's onAppear fire just before
            // the App Intent process writes the pending command. Recheck for a
            // short window so the command is consumed during the same Shortcut run.
            let delays: [UInt64] = [200_000_000, 500_000_000, 1_000_000_000, 1_500_000_000]
            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if consumePendingCommand() {
                    return
                }
            }
        }
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
            guard !controller.hasPairingRecord else { return }
            controller.startPairing()
        }
    }
}
