import Foundation
import Network
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var didStart = false
    private var resolver: AppleMapsRedirectResolver?
    private var bridgeClient: ShareBridgeClient?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = NSLocalizedString("Reading Maps location…", comment: "Share extension initial status")
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)

        spinner.startAnimating()

        closeButton.setTitle(NSLocalizedString("Close", comment: "Share extension close button"), for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        beginImport()
    }

    private func beginImport() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        loadURL(from: providers, index: 0) { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.showError(NSLocalizedString("No Apple Maps link was found in the shared item.", comment: "Share extension missing URL"))
                return
            }
            self.resolve(url)
        }
    }

    private func loadURL(from providers: [NSItemProvider], index: Int, completion: @escaping (URL?) -> Void) {
        guard index < providers.count else {
            loadTextURL(from: providers, index: 0, completion: completion)
            return
        }

        let provider = providers[index]
        let type = UTType.url.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            loadURL(from: providers, index: index + 1, completion: completion)
            return
        }

        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let value = item as? NSURL {
                url = value as URL
            } else if let value = item as? String {
                url = URL(string: value)
            } else {
                url = nil
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    completion(url)
                } else {
                    self.loadURL(from: providers, index: index + 1, completion: completion)
                }
            }
        }
    }

    private func loadTextURL(from providers: [NSItemProvider], index: Int, completion: @escaping (URL?) -> Void) {
        guard index < providers.count else {
            completion(nil)
            return
        }

        let provider = providers[index]
        let type = UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            loadTextURL(from: providers, index: index + 1, completion: completion)
            return
        }

        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            let text = item as? String
            let url = text.flatMap(Self.firstURL(in:))
            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    completion(url)
                } else {
                    self.loadTextURL(from: providers, index: index + 1, completion: completion)
                }
            }
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private func resolve(_ url: URL) {
        if let coordinate = AppleMapsCoordinateParser.parse(url: url) {
            send(coordinate)
            return
        }

        statusLabel.text = NSLocalizedString("Resolving Apple Maps link…", comment: "Share extension resolving status")
        let resolver = AppleMapsRedirectResolver()
        self.resolver = resolver
        resolver.resolve(url) { [weak self] coordinate in
            guard let self else { return }
            self.resolver = nil
            guard let coordinate else {
                self.showError(NSLocalizedString("Could not extract coordinates from this Apple Maps link.", comment: "Share extension coordinate failure"))
                return
            }
            self.send(coordinate)
        }
    }

    private func send(_ coordinate: MapShareCoordinate) {
        statusLabel.text = NSLocalizedString("Sending location to PlaceDrift…", comment: "Share extension sending status")
        let client = ShareBridgeClient()
        bridgeClient = client
        client.send(coordinate: coordinate) { [weak self] success in
            guard let self else { return }
            self.bridgeClient = nil
            if success {
                self.spinner.stopAnimating()
                self.statusLabel.text = NSLocalizedString("Location sent to PlaceDrift.", comment: "Share extension success")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            } else {
                self.showError(NSLocalizedString("PlaceDrift is not reachable. Open PlaceDrift once, enable Maps sharing, and allow Always Location access.", comment: "Share extension bridge failure"))
            }
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        closeButton.isHidden = false
    }

    @objc private func closeTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private final class ShareBridgeClient {
    private let queue = DispatchQueue(label: "com.xepes.placedrift.share-extension-client")
    private var connection: NWConnection?
    private var completion: ((Bool) -> Void)?
    private var finished = false
    private var didSend = false

    func send(coordinate: MapShareCoordinate, completion: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: PlaceDriftShareProtocol.port) else {
            completion(false)
            return
        }

        self.completion = completion
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendPayload(coordinate, over: connection)
            case .failed:
                self.finish(false)
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finish(false)
        }
    }

    private func sendPayload(_ coordinate: MapShareCoordinate, over connection: NWConnection) {
        guard !didSend else { return }
        didSend = true

        guard var data = try? JSONEncoder().encode(
            PlaceDriftShareProtocol.Payload(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) else {
            finish(false)
            return
        }
        data.append(0x0A)

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.finish(false)
                return
            }
            self.receiveAcknowledgement(from: connection)
        })
    }

    private func receiveAcknowledgement(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self] data, _, _, error in
            guard let self else { return }
            guard
                error == nil,
                let data,
                let value = String(data: data, encoding: .utf8),
                value.hasPrefix("OK")
            else {
                self.finish(false)
                return
            }
            self.finish(true)
        }
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(success)
        }
    }
}
