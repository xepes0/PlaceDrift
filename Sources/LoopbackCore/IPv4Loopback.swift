import Foundation

public enum IPv4LoopbackError: Error, Equatable, Sendable {
    case packetTooShort
    case notIPv4
    case invalidHeaderLength
    case invalidTotalLength
}

public struct IPv4LoopbackResult: Equatable, Sendable {
    public let packet: Data
    public let transformed: Bool
    public let source: IPv4Address
    public let destination: IPv4Address

    public init(packet: Data, transformed: Bool, source: IPv4Address, destination: IPv4Address) {
        self.packet = packet
        self.transformed = transformed
        self.source = source
        self.destination = destination
    }
}

/// Pure packet transform used by the Clash Mi integration experiment.
///
/// The transform intentionally mirrors the LocalDevVPN self-device trick, but
/// only for packets whose destination is the configured peer address. All other
/// packets are returned byte-for-byte unchanged so they can continue through
/// Mihomo normally.
///
/// Swapping the IPv4 source and destination addresses does not change the IPv4
/// header checksum or the TCP/UDP pseudo-header checksum because one's-complement
/// addition is commutative: the same two 32-bit addresses are still present,
/// only in the opposite order.
public struct IPv4Loopback: Sendable {
    public let peerAddress: IPv4Address

    public init(peerAddress: IPv4Address) {
        self.peerAddress = peerAddress
    }

    public func transform(_ packet: Data) throws -> IPv4LoopbackResult {
        var bytes = [UInt8](packet)
        guard bytes.count >= 20 else { throw IPv4LoopbackError.packetTooShort }

        let version = bytes[0] >> 4
        guard version == 4 else { throw IPv4LoopbackError.notIPv4 }

        let ihlWords = Int(bytes[0] & 0x0f)
        let headerLength = ihlWords * 4
        guard ihlWords >= 5, headerLength <= bytes.count else {
            throw IPv4LoopbackError.invalidHeaderLength
        }

        let totalLength = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard totalLength >= headerLength, totalLength <= bytes.count else {
            throw IPv4LoopbackError.invalidTotalLength
        }

        let source = IPv4Address.readNetworkOrder(from: bytes, at: 12)
        let destination = IPv4Address.readNetworkOrder(from: bytes, at: 16)

        guard destination == peerAddress else {
            return IPv4LoopbackResult(
                packet: packet,
                transformed: false,
                source: source,
                destination: destination
            )
        }

        destination.writeNetworkOrder(into: &bytes, at: 12)
        source.writeNetworkOrder(into: &bytes, at: 16)

        return IPv4LoopbackResult(
            packet: Data(bytes),
            transformed: true,
            source: destination,
            destination: source
        )
    }
}
