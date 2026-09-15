import Foundation

public struct IPv4Address: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        self.rawValue = value
    }

    public var description: String {
        let a = (rawValue >> 24) & 0xff
        let b = (rawValue >> 16) & 0xff
        let c = (rawValue >> 8) & 0xff
        let d = rawValue & 0xff
        return "\(a).\(b).\(c).\(d)"
    }

    func writeNetworkOrder(into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8((rawValue >> 24) & 0xff)
        bytes[offset + 1] = UInt8((rawValue >> 16) & 0xff)
        bytes[offset + 2] = UInt8((rawValue >> 8) & 0xff)
        bytes[offset + 3] = UInt8(rawValue & 0xff)
    }

    static func readNetworkOrder(from bytes: [UInt8], at offset: Int) -> IPv4Address {
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        return IPv4Address(rawValue: value)
    }
}
