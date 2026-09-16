import AppIntents
import CoreLocation
import Foundation

private enum PlaceDriftShortcutError: LocalizedError {
    case invalidCoordinates
    case missingCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidCoordinates:
            return NSLocalizedString("Invalid coordinates.", comment: "Shortcut coordinate validation error")
        case .missingCoordinate:
            return NSLocalizedString("The selected location has no coordinates.", comment: "Shortcut placemark validation error")
        }
    }
}

struct SetPlaceDriftLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PlaceDrift Location"
    static var description = IntentDescription("Send a Shortcuts location directly to PlaceDrift and start LocationSimulation.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Location")
    var location: CLPlacemark

    func perform() async throws -> some IntentResult {
        guard let coordinate = location.location?.coordinate else {
            throw PlaceDriftShortcutError.missingCoordinate
        }
        guard
            (-90.0...90.0).contains(coordinate.latitude),
            (-180.0...180.0).contains(coordinate.longitude)
        else {
            throw PlaceDriftShortcutError.invalidCoordinates
        }

        await PlaceDriftShortcutRouter.setLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        return .result()
    }
}

struct SetPlaceDriftCoordinatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PlaceDrift Coordinates"
    static var description = IntentDescription("Pass latitude and longitude to PlaceDrift and start LocationSimulation.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Latitude")
    var latitude: Double

    @Parameter(title: "Longitude")
    var longitude: Double

    func perform() async throws -> some IntentResult {
        guard
            (-90.0...90.0).contains(latitude),
            (-180.0...180.0).contains(longitude)
        else {
            throw PlaceDriftShortcutError.invalidCoordinates
        }

        await PlaceDriftShortcutRouter.setLocation(latitude: latitude, longitude: longitude)
        return .result()
    }
}

struct ClearPlaceDriftLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore Real Location"
    static var description = IntentDescription("Clear PlaceDrift LocationSimulation and restore the real device location.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await PlaceDriftShortcutRouter.clearLocation()
        return .result()
    }
}

struct PairPlaceDriftIntent: AppIntent {
    static var title: LocalizedStringResource = "Pair PlaceDrift with This iPhone"
    static var description = IntentDescription("Open PlaceDrift and begin CoreDevice RemotePairing.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await PlaceDriftShortcutRouter.startPairing()
        return .result()
    }
}

struct PlaceDriftAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetPlaceDriftLocationIntent(),
            phrases: [
                "Set location with \(.applicationName)",
                "Use \(.applicationName) to set location",
                "用 \(.applicationName) 设置位置"
            ],
            shortTitle: "Set PlaceDrift Location",
            systemImageName: "location.fill"
        )

        AppShortcut(
            intent: SetPlaceDriftCoordinatesIntent(),
            phrases: [
                "Set coordinates with \(.applicationName)",
                "Use \(.applicationName) coordinates",
                "用 \(.applicationName) 设置坐标"
            ],
            shortTitle: "Set PlaceDrift Coordinates",
            systemImageName: "mappin.and.ellipse"
        )

        AppShortcut(
            intent: ClearPlaceDriftLocationIntent(),
            phrases: [
                "Restore real location with \(.applicationName)",
                "Clear \(.applicationName) location",
                "用 \(.applicationName) 恢复真实位置"
            ],
            shortTitle: "Restore Real Location",
            systemImageName: "location.slash"
        )
    }
}
