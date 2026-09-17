import Foundation
import Network

final class PlaceDriftShareBridge {
    var onLocation: ((Double, Double) -> Void)?
    var onReadyChange: ((Bool) -> Void)?
    var onPortChange: ((UInt16?) -> Void)?
    var onErrorChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "com.xepes.placedrift.share-bridge")
    private var listener: NWListener?
    private var retryWorkItem: DispatchWorkItem?
    private var wantsRunning = false
    private var portIndex = 0
    private var lastFailure: String?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            if self.listener == nil {
                self.portIndex = 0
                self.lastFailure = nil
                self.startOnQueue()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.portIndex = 0
            self.lastFailure = nil
            self.publishReady(false)
            self.publishPort(nil)
            self.publishError(nil)
        }
    }

    private func startOnQueue() {
        guard wantsRunning, listener == nil else { return }

        guard portIndex < PlaceDriftShareProtocol.ports.count else {
            publishReady(false)
            publishPort(nil)
            let detail = lastFailure ?? "unknown listener error"
            publishError("All loopback share ports are unavailable. Last error: \(detail)")
            scheduleFullRetry()
            return
        }

        let candidate = PlaceDriftShareProtocol.ports[portIndex]
        guard let port = NWEndpoint.Port(rawValue: candidate) else {
            lastFailure = "invalid port \(candidate)"
            portIndex += 1
            startOnQueue()
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.lastFailure = nil
                    self.publishError(nil)
                    self.publishPort(candidate)
                    self.publishReady(true)

                case .waiting(let error):
                    self.advanceAfterFailure(listener: listener, port: candidate, error: error)

                case .failed(let error):
                    self.advanceAfterFailure(listener: listener, port: candidate, error: error)

                case .cancelled:
                    self.listener = nil
                    self.publishReady(false)
                    self.publishPort(nil)
                    if self.wantsRunning {
                        self.portIndex += 1
                        self.startOnQueue()
                    }

                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            lastFailure = "port \(candidate): \(error.localizedDescription)"
            publishReady(false)
            publishPort(nil)
            publishError(lastFailure)
            portIndex += 1
            startOnQueue()
        }
    }

    private func advanceAfterFailure(listener: NWListener, port: UInt16, error: NWError) {
        guard self.listener === listener else { return }
        lastFailure = "port \(port): \(error)"
        publishReady(false)
        publishPort(nil)
        publishError(lastFailure)

        listener.stateUpdateHandler = nil
        listener.cancel()
        self.listener = nil
        portIndex += 1
        startOnQueue()
    }

    private func scheduleFullRetry() {
        guard wantsRunning, retryWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.portIndex = 0
            self.startOnQueue()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func accept(_ connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data {
                next.append(data)
            }

            if let newline = next.firstIndex(of: 0x0A) {
                let frame = Data(next[..<newline])
                self.handle(frame, on: connection)
                return
            }

            guard error == nil, !isComplete, next.count <= 4096 else {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: next)
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard
            let payload = try? JSONDecoder().decode(PlaceDriftShareProtocol.Payload.self, from: data),
            payload.version == PlaceDriftShareProtocol.version,
            payload.latitude.isFinite,
            payload.longitude.isFinite,
            (-90.0...90.0).contains(payload.latitude),
            (-180.0...180.0).contains(payload.longitude)
        else {
            connection.cancel()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onLocation?(payload.latitude, payload.longitude)
        }

        connection.send(content: Data("OK\n".utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private func publishReady(_ ready: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onReadyChange?(ready)
        }
    }

    private func publishPort(_ port: UInt16?) {
        DispatchQueue.main.async { [weak self] in
            self?.onPortChange?(port)
        }
    }

    private func publishError(_ error: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onErrorChange?(error)
        }
    }
}
