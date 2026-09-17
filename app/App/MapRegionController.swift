import Combine
import Foundation

@MainActor
final class MapRegionController: ObservableObject {
    @Published private(set) var currentCountryCode = "—"
    @Published private(set) var status = "Not applied"
    @Published private(set) var lastError: String?

    private static let savedOriginalKey = "placedrift.map-region.original-country-code"

    init() {
        refresh()
    }

    func refresh() {
        var buffer = [CChar](repeating: 0, count: 32)
        if placedrift_geoservices_get_country_code(&buffer, buffer.count) {
            currentCountryCode = String(cString: buffer)
        } else {
            currentCountryCode = "—"
        }
    }

    func applyUSRegion() {
        refresh()
        if UserDefaults.standard.string(forKey: Self.savedOriginalKey) == nil,
           currentCountryCode.count == 2 {
            UserDefaults.standard.set(currentCountryCode, forKey: Self.savedOriginalKey)
        }
        apply(countryCode: "US", successStatus: "US GeoServices region applied")
    }

    func restoreSavedRegion() {
        guard let original = UserDefaults.standard.string(forKey: Self.savedOriginalKey), original.count == 2 else {
            status = "No saved region to restore"
            lastError = nil
            return
        }
        apply(countryCode: original, successStatus: "Saved GeoServices region restored")
    }

    private func apply(countryCode: String, successStatus: String) {
        var errorBuffer = [CChar](repeating: 0, count: 256)
        let success = countryCode.withCString { code in
            placedrift_geoservices_set_country_code(code, &errorBuffer, errorBuffer.count)
        }

        refresh()
        if success {
            status = successStatus
            lastError = nil
        } else {
            status = "GeoServices region write failed"
            let message = String(cString: errorBuffer)
            lastError = message.isEmpty ? "Unknown GeoServices error" : message
        }
    }
}
