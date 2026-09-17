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
            return NSLocalizedString("No coordinates were received from Shortcuts.", comment: "Shortcut missing coordinate error")
        }
    }
}

private func parseShortcutCoordinate(_ value: String?) -> Double? {
    guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }

    // Dictionary values returned by WLOC /api/parse may reach App Intents through
    // Shortcuts as text rather than as a native Double. Parse them inside PlaceDrift
    // instead of asking Shortcuts to coerce the magic variable into a Double first.
    text = text
        .replacingOccurrences(of: "−", with: "-")
        .replacingOccurrences(of: "＋", with: "+")
        .replacingOccurrences(of: "，", with: ",")

    if let direct = Double(text) {
        return direct
    }

    // Also tolerate a simple localized decimal comma when there is no decimal point.
    if !text.contains("."), text.filter({ $0 == "," }).count == 1 {
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }
    return nil
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

    // WLOC's proven Shortcut path takes lat/lon from a JSON dictionary and inserts
    // them into a URL as text. Using Double here made App Intents perform its own
    // runtime type resolution; when that failed, Shortcuts treated the parameter as
    // missing and displayed an interactive latitude/longitude prompt. Accept text and
    // parse it ourselves so dictionary magic variables arrive unchanged.
    @Parameter(title: "Latitude")
    var latitude: String?

    @Parameter(title: "Longitude")
    var longitude: String?

    func perform() async throws -> some IntentResult {
        guard
            let latitude = parseShortcutCoordinate(latitude),
            let longitude = parseShortcutCoordinate(longitude)
        else {
            throw PlaceDriftShortcutError.missingCoordinate
        }
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
