import Foundation
import Network
import SwiftUI

@MainActor
final class TransportHealthMonitor: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown
        case checking
        case connected
        case disconnected
        case noRemotePairingService
    }

    @Published private(set) var state: State = .unknown

    private let targetHost = NWEndpoint.Host("10.7.0.1")
    private let probeQueue = DispatchQueue(label: "com.xepes.placedrift.transport-probe", qos: .utility)
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var connections: [NWConnection] = []
    private var timeoutTask: Task<Void, Never>?
    private var runID = UUID()
    private var sawResolvedPort = false
    private var probedPorts = Set<UInt16>()

    func refresh() {
        stopResources()
        state = .checking

        sawResolvedPort = false
        probedPorts.removeAll()
        let currentRunID = UUID()
        runID = currentRunID

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        self.browser = browser
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard
                !Task.isCancelled,
                let self,
                self.runID == currentRunID,
                self.state == .checking
            else { return }

            self.finish(self.sawResolvedPort ? .disconnected : .noRemotePairingService)
        }
    }

    func reset() {
        stopResources()
        state = .unknown
    }

    private func resolve(_ service: NetService) {
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 2)
        services.append(service)
    }

    private func probe(_ service: NetService) {
        guard service.port > 0, service.port <= Int(UInt16.max) else { return }
        let rawPort = UInt16(service.port)
        guard probedPorts.insert(rawPort).inserted else { return }
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { return }

        sawResolvedPort = true
        let expectedRunID = runID
        let connection = NWConnection(host: targetHost, port: port, using: .tcp)
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let connection else { return }

            switch connectionState {
            case .ready:
                guard let frame = Self.attemptPairVerifyFrame() else {
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == expectedRunID else { return }
                        self.finish(.disconnected)
                    }
                    return
                }

                connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                    guard error == nil, let connection else { return }
                    self?.receiveRemotePairingFrame(
                        connection,
                        buffer: Data(),
                        expectedRunID: expectedRunID
                    )
                })

            case .failed:
                break

            default:
                break
            }
        }

        connection.start(queue: probeQueue)
    }

    private nonisolated func receiveRemotePairingFrame(
        _ connection: NWConnection,
        buffer: Data,
        expectedRunID: UUID
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }

            var accumulated = buffer
            if let content, !content.isEmpty {
                accumulated.append(content)
            }

            switch Self.remotePairingProbeResult(accumulated) {
            case .valid:
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        self.runID == expectedRunID,
                        self.state == .checking
                    else { return }
                    self.finish(.connected)
                }

            case .invalid:
                // A complete RPPairing frame arrived, but it was not a real
                // attemptPairVerify handshake response. Do not turn green.
                break

            case .incomplete:
                if error == nil, !isComplete {
                    self.receiveRemotePairingFrame(
                        connection,
                        buffer: accumulated,
                        expectedRunID: expectedRunID
                    )
                }
            }
        }
    }

    private enum ProbeResult {
        case incomplete
        case invalid
        case valid
    }

    private nonisolated static func attemptPairVerifyFrame() -> Data? {
        let envelope: [String: Any] = [
            "message": [
                "plain": [
                    "_0": [
                        "request": [
                            "_0": [
                                "handshake": [
                                    "_0": [
                                        "hostOptions": ["attemptPairVerify": true],
                                        "wireProtocolVersion": 19
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ],
            "originatedBy": "host",
            "sequenceNumber": 0
        ]

        guard
            JSONSerialization.isValidJSONObject(envelope),
            let json = try? JSONSerialization.data(withJSONObject: envelope),
            json.count <= Int(UInt16.max)
        else { return nil }

        var frame = Data("RPPairing".utf8)
        var length = UInt16(json.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            frame.append(contentsOf: bytes)
        }
        frame.append(json)
        return frame
    }

    private nonisolated static func remotePairingProbeResult(_ data: Data) -> ProbeResult {
        let magic = Data("RPPairing".utf8)
        let headerLength = magic.count + 2
        guard data.count >= headerLength else { return .incomplete }
        guard data.prefix(magic.count) == magic else { return .invalid }

        let lengthOffset = magic.count
        let bodyLength = (Int(data[lengthOffset]) << 8) | Int(data[lengthOffset + 1])
        guard data.count >= headerLength + bodyLength else { return .incomplete }

        let body = data.subdata(in: headerLength..<(headerLength + bodyLength))
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let root = object as? [String: Any],
            let message = root["message"] as? [String: Any],
            let plain = message["plain"] as? [String: Any],
            let payload = plain["_0"] as? [String: Any],
            let response = payload["response"] as? [String: Any],
            let responseBody = response["_1"] as? [String: Any],
            let handshake = responseBody["handshake"] as? [String: Any],
            handshake["_0"] != nil
        else {
            return .invalid
        }

        return .valid
    }

    private func finish(_ newState: State) {
        stopResources()
        state = newState
    }

    private func stopResources() {
        timeoutTask?.cancel()
        timeoutTask = nil

        browser?.stop()
        browser?.delegate = nil
        browser = nil

        services.forEach {
            $0.stop()
            $0.remove(from: .main, forMode: .common)
            $0.delegate = nil
        }
        services.removeAll()

        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}

extension TransportHealthMonitor: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            self?.resolve(service)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            self?.probe(sender)
        }
    }
}
