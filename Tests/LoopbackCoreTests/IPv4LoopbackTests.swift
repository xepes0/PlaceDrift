import Foundation
import Testing
@testable import LoopbackCore

private func makeIPv4Packet(
    source: String,
    destination: String,
    protocolNumber: UInt8 = 6,
    payload: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
) -> Data {
    let src = IPv4Address(source)!
    let dst = IPv4Address(destination)!
    let totalLength = 20 + payload.count

    var bytes = [UInt8](repeating: 0, count: totalLength)
    bytes[0] = 0x45
    bytes[1] = 0
    bytes[2] = UInt8((totalLength >> 8) & 0xff)
    bytes[3] = UInt8(totalLength & 0xff)
    bytes[4] = 0x12
    bytes[5] = 0x34
    bytes[6] = 0x40
    bytes[7] = 0
    bytes[8] = 64
    bytes[9] = protocolNumber
    bytes[10] = 0xab
    bytes[11] = 0xcd
    src.writeNetworkOrder(into: &bytes, at: 12)
    dst.writeNetworkOrder(into: &bytes, at: 16)
    bytes.replaceSubrange(20..<totalLength, with: payload)
    return Data(bytes)
}

@Test("10.7.0.1 traffic is reflected back to the device")
func reflectsPeerTraffic() throws {
    let loopback = IPv4Loopback(peerAddress: IPv4Address("10.7.0.1")!)
    let original = makeIPv4Packet(source: "10.7.0.2", destination: "10.7.0.1")

    let result = try loopback.transform(original)

    #expect(result.transformed)
    #expect(result.source == IPv4Address("10.7.0.1"))
    #expect(result.destination == IPv4Address("10.7.0.2"))

    let output = [UInt8](result.packet)
    let input = [UInt8](original)
    #expect(Array(output[0..<12]) == Array(input[0..<12]))
    #expect(Array(output[20..<output.count]) == Array(input[20..<input.count]))
}

@Test("unrelated Mihomo traffic is untouched")
func leavesOtherTrafficUntouched() throws {
    let loopback = IPv4Loopback(peerAddress: IPv4Address("10.7.0.1")!)
    let original = makeIPv4Packet(source: "198.18.0.1", destination: "1.1.1.1")

    let result = try loopback.transform(original)

    #expect(!result.transformed)
    #expect(result.packet == original)
}

@Test("IPv6 is rejected instead of accidentally rewritten")
func rejectsIPv6() {
    let loopback = IPv4Loopback(peerAddress: IPv4Address("10.7.0.1")!)
    var packet = [UInt8](repeating: 0, count: 40)
    packet[0] = 0x60

    #expect(throws: IPv4LoopbackError.notIPv4) {
        _ = try loopback.transform(Data(packet))
    }
}

@Test("truncated packets fail closed")
func rejectsTruncatedPacket() {
    let loopback = IPv4Loopback(peerAddress: IPv4Address("10.7.0.1")!)

    #expect(throws: IPv4LoopbackError.packetTooShort) {
        _ = try loopback.transform(Data([0x45, 0, 0, 20]))
    }
}
