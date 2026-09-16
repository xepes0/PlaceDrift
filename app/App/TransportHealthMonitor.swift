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

    func refresh() {
        stopResources()

        // Do not keep showing a stale green state while a new probe is running.
        // Some TUN implementations can report the synthetic TCP socket as ready
        // before the policy engine has rejected the flow.
        state = .checking

        sawResolvedPort = false
        let currentRunID = UUID()
        runID = currentRunID

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        self.browser = browser
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard
                !Task.isCancelled,
                let self,
                self.runID == currentRunID
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
        guard let port = NWEndpoint.Port(rawValue: UInt16(service.port)) else { return }

        sawResolvedPort = true
        let expectedRunID = runID

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 1
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 1
        let parameters = NWParameters(tls: nil, tcp: tcp)

        let connection = NWConnection(host: targetHost, port: port, using: parameters)
        connections.append(connection)

        // NWConnection.ready alone is not enough for a synthetic TUN endpoint.
        // Loon/other user-space TCP stacks may briefly acknowledge the local
        // socket and only deliver the REJECT/RST immediately afterwards. Keep
        // the socket alive for a short validation window and only turn green
        // if it remains ready for the full window.
        var remainsReady = false
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            switch connectionState {
            case .ready:
                remainsReady = true
                self?.probeQueue.asyncAfter(deadline: .now() + 1.0) { [weak self, weak connection] in
                    guard remainsReady else { return }
                    connection?.cancel()
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == expectedRunID else { return }
                        self.finish(.connected)
                    }
                }

            case .waiting, .failed, .cancelled:
                remainsReady = false

            default:
                break
            }
        }

        connection.start(queue: probeQueue)
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
