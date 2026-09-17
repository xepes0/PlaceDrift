import Foundation

enum PlaceDriftShareProtocol {
    static let version = 1
    static let port: UInt16 = 57874

    struct Payload: Codable {
        let version: Int
        let latitude: Double
        let longitude: Double
        let source: String?

        init(latitude: Double, longitude: Double, source: String? = nil) {
            self.version = PlaceDriftShareProtocol.version
            self.latitude = latitude
            self.longitude = longitude
            self.source = source
        }
    }
}
