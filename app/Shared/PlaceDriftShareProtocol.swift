import Foundation

enum PlaceDriftShareProtocol {
    static let version = 2

    // Keep IPC fully local and independent from App Groups. The host picks the
    // first free loopback port, while the Share Extension probes this same pool.
    // Version 2 prevents an older installed PlaceDrift copy from accepting a
    // Build 17 payload on the original fixed port.
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
