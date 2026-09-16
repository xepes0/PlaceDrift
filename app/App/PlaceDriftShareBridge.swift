import Foundation
import Network

final class PlaceDriftShareBridge {
    var onLocation: ((Double, Double) -> Void)?
    var onReadyChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.xepes.placedrift.share-bridge")
    private var listener: NWListener?

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.publishReady(false)
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: PlaceDriftShareProtocol.port) else {
            publishReady(false)
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publishReady(true)
                case .failed, .cancelled:
                    if self.listener === listener {
                        self.listener = nil
                    }
                    self.publishReady(false)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listener = nil
            publishReady(false)
        }
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
}
