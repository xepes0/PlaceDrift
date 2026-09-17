import Foundation

enum PlaceDriftShareProtocol {
    static let version = 2

    // SideStore/re-signed builds can leave another signed copy or process holding
    // the original fixed port. Both the host app and Share Extension use this
    // deterministic loopback-only pool so the host can move to a free port and
    // the extension can discover it without App Groups or shared entitlements.
    static let ports: [UInt16] = Array(57874...57889)

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
