import AppIntents
import CoreLocation
import Foundation

private enum PlaceDriftShortcutError: LocalizedError {
    case invalidCoordinates
    case missingCoordinate
    case unsupportedMapShare

    var errorDescription: String? {
        switch self {
        case .invalidCoordinates:
            return NSLocalizedString("Invalid coordinates.", comment: "Shortcut coordinate validation error")
        case .missingCoordinate:
            return NSLocalizedString("No coordinates were received from Shortcuts.", comment: "Shortcut missing coordinate error")
        case .unsupportedMapShare:
            return NSLocalizedString("Could not extract coordinates from the shared map item.", comment: "Shortcut local map parser error")
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

    let separatedPattern = #"(-?\d{1,2}(?:\.\d+)?)\s*[,;|\s]\s*(-?\d{1,3}(?:\.\d+)?)"#
    if let regex = try? NSRegularExpression(pattern: separatedPattern),
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

    // Be tolerant of Shortcuts text blocks that place two magic variables next to
    // quotes or other punctuation without an explicit comma. Take the first two
    // decimal numbers and validate their latitude/longitude ranges afterward.
    let numberPattern = #"-?\d{1,3}(?:\.\d+)?"#
    if let regex = try? NSRegularExpression(pattern: numberPattern) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        if matches.count >= 2,
           let firstRange = Range(matches[0].range, in: text),
           let secondRange = Range(matches[1].range, in: text),
           let latitude = Double(text[firstRange]),
           let longitude = Double(text[secondRange]) {
            return (latitude, longitude)
        }
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

@MainActor
private func resolveShortcutMapShare(_ rawInput: String) async -> MapShareCoordinate? {
    let resolver = PlaceDriftShortcutMapResolver()
    return await resolver.resolve(rawInput)
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

// Build 14: accept the original map share text directly. This removes the old
// Shortcut dependency on the WLOC /api/parse request and uses the same local
// Apple/Amap/Baidu parsing stack as the Share Extension.
struct SetPlaceDriftFromMapShareIntent: AppIntent {
    static var title: LocalizedStringResource = "Set PlaceDrift from Map Share"
    static var description = IntentDescription("Parse a shared Apple Maps, Amap, or Baidu Maps item locally and set PlaceDrift location without a Worker request.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Map Share Text")
    var mapShareText: String

    func perform() async throws -> some IntentResult {
        guard let coordinate = await resolveShortcutMapShare(mapShareText) else {
            throw PlaceDriftShortcutError.unsupportedMapShare
        }
        try validateCoordinatePair(coordinate.latitude, coordinate.longitude)
        await PlaceDriftShortcutRouter.setLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
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
            intent: SetPlaceDriftFromMapShareIntent(),
            phrases: [
                "Set map share with \(.applicationName)",
                "Use \(.applicationName) map share",
                "用 \(.applicationName) 设置地图分享位置"
            ],
            shortTitle: "Set from Map Share",
            systemImageName: "map.fill"
        )

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
