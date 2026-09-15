import Foundation

public enum WLOCDeepLinkAction: String, Codable, Sendable {
    case pair
    case set
    case update
    case clear
    case status
}

public struct WLOCDeepLinkRequest: Equatable, Sendable {
    public let action: WLOCDeepLinkAction
    public let latitude: Double?
    public let longitude: Double?
    public let callback: URL?
    public let requestID: String?

    public init(
        action: WLOCDeepLinkAction,
        latitude: Double? = nil,
        longitude: Double? = nil,
        callback: URL? = nil,
        requestID: String? = nil
    ) {
        self.action = action
        self.latitude = latitude
        self.longitude = longitude
        self.callback = callback
        self.requestID = requestID
    }

    public static func parse(_ url: URL) -> WLOCDeepLinkRequest? {
        guard url.scheme?.lowercased() == "clashmi", url.host?.lowercased() == "wloc" else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let action = WLOCDeepLinkAction(rawValue: path.lowercased()) else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        func uniqueValue(_ name: String) -> String? {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            guard values.count <= 1 else { return nil }
            return values.first
        }

        let latString = uniqueValue("lat")
        let lonString = uniqueValue("lon")
        let latitude = latString.flatMap(Double.init)
        let longitude = lonString.flatMap(Double.init)
        let callback = uniqueValue("callback").flatMap(URL.init(string:))
        let requestID = uniqueValue("rid")

        if action == .set || action == .update {
            guard let latitude, let longitude,
                  latitude.isFinite, longitude.isFinite,
                  (-90.0...90.0).contains(latitude),
                  (-180.0...180.0).contains(longitude)
            else { return nil }
        }

        return WLOCDeepLinkRequest(
            action: action,
            latitude: latitude,
            longitude: longitude,
            callback: callback,
            requestID: requestID
        )
    }
}

public struct WLOCProviderEnvelope: Codable, Equatable, Sendable {
    public let messageId: String
    public let messageParams: String

    public init(messageId: String, messageParams: String = "") {
        self.messageId = messageId
        self.messageParams = messageParams
    }
}

public struct WLOCSetRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let pairingRecordBase64: String
    public let peerAddress: String
    public let remotePairingPort: UInt16
    public let serviceIdentifier: String
    public let authTag: String
    public let latitude: Double
    public let longitude: Double

    public init(
        requestID: String,
        pairingRecordBase64: String,
        peerAddress: String = "10.7.0.1",
        remotePairingPort: UInt16,
        serviceIdentifier: String,
        authTag: String,
        latitude: Double,
        longitude: Double
    ) {
        self.requestID = requestID
        self.pairingRecordBase64 = pairingRecordBase64
        self.peerAddress = peerAddress
        self.remotePairingPort = remotePairingPort
        self.serviceIdentifier = serviceIdentifier
        self.authTag = authTag
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WLOCUpdateRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let latitude: Double
    public let longitude: Double

    public init(requestID: String, latitude: Double, longitude: Double) {
        self.requestID = requestID
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct WLOCSimpleRequest: Codable, Equatable, Sendable {
    public let requestID: String

    public init(requestID: String) {
        self.requestID = requestID
    }
}

public enum WLOCTunnelState: String, Codable, Sendable {
    case idle
    case connecting
    case active
    case clearing
    case failed
}

public struct WLOCProviderResponse: Codable, Equatable, Sendable {
    public let requestID: String?
    public let ok: Bool
    public let state: WLOCTunnelState
    public let failureStage: UInt32?
    public let errorCode: String?

    public init(
        requestID: String?,
        ok: Bool,
        state: WLOCTunnelState,
        failureStage: UInt32? = nil,
        errorCode: String? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.state = state
        self.failureStage = failureStage
        self.errorCode = errorCode
    }
}

public enum WLOCProviderMessageID {
    public static let set = "wloc.set"
    public static let update = "wloc.update"
    public static let clear = "wloc.clear"
    public static let status = "wloc.status"

    public static func isWLOC(_ value: String) -> Bool {
        value.hasPrefix("wloc.")
    }
}
