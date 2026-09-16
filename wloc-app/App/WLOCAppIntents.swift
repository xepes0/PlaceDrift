import AppIntents
import CoreLocation
import Foundation

private enum WLOCShortcutError: LocalizedError {
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

struct SetWLOCLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Set WLOC Location"
    static var description = IntentDescription("Send a Shortcuts location directly to WLOC and start LocationSimulation.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Location")
    var location: CLPlacemark

    func perform() async throws -> some IntentResult {
        guard let coordinate = location.location?.coordinate else {
            throw WLOCShortcutError.missingCoordinate
        }
        guard
            (-90.0...90.0).contains(coordinate.latitude),
            (-180.0...180.0).contains(coordinate.longitude)
        else {
            throw WLOCShortcutError.invalidCoordinates
        }

        await WLOCShortcutRouter.setLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        return .result()
    }
}

struct SetWLOCCoordinatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Set WLOC Coordinates"
    static var description = IntentDescription("Pass latitude and longitude to WLOC and start LocationSimulation.")
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
            throw WLOCShortcutError.invalidCoordinates
        }

        await WLOCShortcutRouter.setLocation(latitude: latitude, longitude: longitude)
        return .result()
    }
}

struct ClearWLOCLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore Real Location"
    static var description = IntentDescription("Clear WLOC LocationSimulation and restore the real device location.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await WLOCShortcutRouter.clearLocation()
        return .result()
    }
}

struct PairWLOCIntent: AppIntent {
    static var title: LocalizedStringResource = "Pair WLOC with This iPhone"
    static var description = IntentDescription("Open WLOC and begin CoreDevice RemotePairing.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await WLOCShortcutRouter.startPairing()
        return .result()
    }
}

struct WLOCAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWLOCLocationIntent(),
            phrases: [
                "Set location with \(.applicationName)",
                "Use \(.applicationName) to set location",
                "用 \(.applicationName) 设置位置"
            ],
            shortTitle: "Set WLOC Location",
            systemImageName: "location.fill"
        )

        AppShortcut(
            intent: SetWLOCCoordinatesIntent(),
            phrases: [
                "Set coordinates with \(.applicationName)",
                "Use \(.applicationName) coordinates",
                "用 \(.applicationName) 设置坐标"
            ],
            shortTitle: "Set WLOC Coordinates",
            systemImageName: "mappin.and.ellipse"
        )

        AppShortcut(
            intent: ClearWLOCLocationIntent(),
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
