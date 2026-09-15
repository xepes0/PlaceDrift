import Foundation
import Testing
@testable import ClashMiBridgeProtocol

@Test func parsesSetDeepLink() throws {
    let url = try #require(URL(string: "clashmi://wloc/set?lat=34.052235&lon=-118.243683&rid=abc123&callback=https%3A%2F%2Fexample.com%2Fdone"))
    let request = try #require(WLOCDeepLinkRequest.parse(url))
    #expect(request.action == .set)
    #expect(request.latitude == 34.052235)
    #expect(request.longitude == -118.243683)
    #expect(request.requestID == "abc123")
    #expect(request.callback?.absoluteString == "https://example.com/done")
}

@Test func rejectsDuplicateCoordinates() throws {
    let url = try #require(URL(string: "clashmi://wloc/set?lat=1&lat=2&lon=3"))
    #expect(WLOCDeepLinkRequest.parse(url) == nil)
}

@Test func rejectsOutOfRangeCoordinates() throws {
    let url = try #require(URL(string: "clashmi://wloc/set?lat=91&lon=0"))
    #expect(WLOCDeepLinkRequest.parse(url) == nil)
}

@Test func clearDoesNotRequireCoordinates() throws {
    let url = try #require(URL(string: "clashmi://wloc/clear?rid=clear1"))
    let request = try #require(WLOCDeepLinkRequest.parse(url))
    #expect(request.action == .clear)
    #expect(request.latitude == nil)
    #expect(request.longitude == nil)
}

@Test func providerSetPayloadRoundTrips() throws {
    let request = WLOCSetRequest(
        requestID: "r1",
        pairingRecordBase64: "AAECAwQ=",
        remotePairingPort: 49152,
        serviceIdentifier: "device-id",
        authTag: "auth-tag",
        latitude: 35.681236,
        longitude: 139.767125
    )
    let paramsData = try JSONEncoder().encode(request)
    let params = try #require(String(data: paramsData, encoding: .utf8))
    let envelope = WLOCProviderEnvelope(messageId: WLOCProviderMessageID.set, messageParams: params)
    let encoded = try JSONEncoder().encode(envelope)
    let decodedEnvelope = try JSONDecoder().decode(WLOCProviderEnvelope.self, from: encoded)
    let decodedRequest = try JSONDecoder().decode(WLOCSetRequest.self, from: Data(decodedEnvelope.messageParams.utf8))
    #expect(decodedEnvelope.messageId == "wloc.set")
    #expect(decodedRequest == request)
}

@Test func providerResponseRoundTrips() throws {
    let response = WLOCProviderResponse(
        requestID: "r2",
        ok: false,
        state: .failed,
        failureStage: 4,
        errorCode: "tls_psk_failed"
    )
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(WLOCProviderResponse.self, from: data)
    #expect(decoded == response)
}
