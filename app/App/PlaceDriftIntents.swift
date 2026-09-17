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

private func normalizeShortcutText(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "−", with: "-")
        .replacingOccurrences(of: "＋", with: "+")
        .replacingOccurrences(of: "，", with: ",")
}

private func parseShortcutCoordinate(_ value: String?) -> Double? {
    guard let value else { return nil }
    let text = normalizeShortcutText(value)
    guard !text.isEmpty else { return nil }

    if let direct = Double(text) {
        return direct
    }

    if !text.contains("."), text.filter({ $0 == "," }).count == 1 {
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }
    return nil
}

private func parseCoordinatePair(_ rawValue: String) -> (Double, Double)? {
    let text = normalizeShortcutText(rawValue)
    guard !text.isEmpty else { return nil }

    if let url = URL(string: text),
       url.scheme?.lowercased() == "placedrift",
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let latText = components.queryItems?.first(where: { $0.name == "lat" })?.value,
       let lonText = components.queryItems?.first(where: { $0.name == "lon" })?.value,
       let latitude = Double(latText),
       let longitude = Double(lonText) {
        return (latitude, longitude)
    }

    if let data = text.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        func number(_ key: String) -> Double? {
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String { return Double(normalizeShortcutText(value)) }
            return nil
        }
        if let latitude = number("lat") ?? number("latitude"),
           let longitude = number("lon") ?? number("lng") ?? number("longitude") {
            return (latitude, longitude)
        }
    }

    let pattern = #"(-?\d{1,2}(?:\.\d+)?)\s*[,;|\s]\s*(-?\d{1,3}(?:\.\d+)?)"#
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
       ),
       let latRange = Range(match.range(at: 1), in: text),
       let lonRange = Range(match.range(at: 2), in: text),
       let latitude = Double(text[latRange]),
       let longitude = Double(text[lonRange]) {
        return (latitude, longitude)
    }

    return nil
}

private func validateCoordinatePair(_ latitude: Double, _ longitude: Double) throws {
    guard
        latitude.isFinite,
        longitude.isFinite,
        (-90.0...90.0).contains(latitude),
        (-180.0...180.0).contains(longitude)
    else {
        throw PlaceDriftShortcutError.invalidCoordinates
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
        try validateCoordinatePair(coordinate.latitude, coordinate.longitude)

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
        try validateCoordinatePair(latitude, longitude)

        await PlaceDriftShortcutRouter.setLocation(latitude: latitude, longitude: longitude)
        return .result()
    }
}

// Build 11 intentionally uses a brand-new AppIntent type and only one text field.
// This avoids both the cached schema of the older two-parameter action and Shortcuts'
// unreliable coercion of JSON dictionary values into two independent parameters.
struct SetPlaceDriftCoordinateTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PlaceDrift Coordinate Text"
    static var description = IntentDescription("Pass one coordinate pair such as 22.293882,114.174130 to PlaceDrift.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Coordinates")
    var coordinates: String

    func perform() async throws -> some IntentResult {
        guard let (latitude, longitude) = parseCoordinatePair(coordinates) else {
            throw PlaceDriftShortcutError.missingCoordinate
        }
        try validateCoordinatePair(latitude, longitude)
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
            intent: SetPlaceDriftCoordinateTextIntent(),
            phrases: [
                "Set coordinate text with \(.applicationName)",
                "Use \(.applicationName) coordinate text",
                "用 \(.applicationName) 设置坐标文本"
            ],
            shortTitle: "Set PlaceDrift Coordinate Text",
            systemImageName: "text.badge.checkmark"
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
