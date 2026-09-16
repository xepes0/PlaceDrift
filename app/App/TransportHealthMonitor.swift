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
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var connections: [NWConnection] = []
    private var timeoutTask: Task<Void, Never>?
    private var runID = UUID()
    private var sawResolvedPort = false

    func refresh() {
        stopResources()

        let previousState = state
        if previousState != .connected {
            state = .checking
        }

        sawResolvedPort = false
        let currentRunID = UUID()
        runID = currentRunID

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = true
        self.browser = browser
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
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
        let connection = NWConnection(host: targetHost, port: port, using: .tcp)
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard case .ready = connectionState else { return }
            connection?.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.runID == expectedRunID else { return }
                self.finish(.connected)
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))
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
