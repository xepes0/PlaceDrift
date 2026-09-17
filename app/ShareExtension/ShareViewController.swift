import Foundation
import Network
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var didStart = false
    private var resolver: MapShareRedirectResolver?
    private var baiduResolver: BaiduWebViewCoordinateResolver?
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
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        beginImport()
    }

    private func beginImport() {
        collectSharedInput { [weak self] input in
            guard let self else { return }
            guard !input.urls.isEmpty || !input.texts.isEmpty else {
                self.showError(NSLocalizedString("No supported map link was found in the shared item.", comment: "Share extension missing URL"))
                return
            }
            self.resolve(input)
        }
    }

    private struct SharedMapInput {
        let urls: [URL]
        let texts: [String]

        var combinedText: String {
            var parts = texts
            parts.append(contentsOf: urls.map(\.absoluteString))
            var seen = Set<String>()
            return parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .joined(separator: "\n")
        }
    }

    private func collectSharedInput(completion: @escaping (SharedMapInput) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var urls: [URL] = []
        var texts: [String] = items.compactMap { $0.attributedContentText?.string }
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
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
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let text: String?
                    if let value = item as? String {
                        text = value
                    } else if let value = item as? NSAttributedString {
                        text = value.string
                    } else {
                        text = nil
                    }
                    if let text, !text.isEmpty {
                        lock.lock()
                        texts.append(text)
                        lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            var seenURLs = Set<String>()
            let uniqueURLs = urls.filter { seenURLs.insert($0.absoluteString).inserted }
            var seenTexts = Set<String>()
            let uniqueTexts = texts.filter { seenTexts.insert($0).inserted }
            completion(SharedMapInput(urls: uniqueURLs, texts: uniqueTexts))
        }
    }

    private func resolve(_ input: SharedMapInput) {
        for text in input.texts {
            if let coordinate = MapShareCoordinateParser.parse(text: text, providerHint: .unknown, allowBare: false) {
                send(coordinate, source: "Local direct parser")
                return
            }
        }
        for url in input.urls {
            if let coordinate = MapShareCoordinateParser.parse(url: url) {
                send(coordinate, source: "Local direct parser")
                return
            }
        }

        let combined = input.combinedText
        if !combined.isEmpty,
           let coordinate = MapShareCoordinateParser.parse(
            text: combined,
            providerHint: .unknown,
            allowBare: true
           ) {
            send(coordinate, source: "Local combined parser")
            return
        }

        resolveRedirects(input.urls, index: 0, originalInput: input)
    }

    private func resolveRedirects(_ urls: [URL], index: Int, originalInput: SharedMapInput) {
        guard index < urls.count else {
            finishWithBaiduFallback(originalInput)
            return
        }

        let url = urls[index]
        statusLabel.text = NSLocalizedString("Resolving map link locally…", comment: "Share extension local resolving status")
        let resolver = MapShareRedirectResolver()
        self.resolver = resolver
        resolver.resolve(url) { [weak self] coordinate in
            guard let self else { return }
            self.resolver = nil
            if let coordinate {
                self.send(coordinate, source: "Local redirect/page parser")
            } else {
                self.resolveRedirects(urls, index: index + 1, originalInput: originalInput)
            }
        }
    }

    private func finishWithBaiduFallback(_ input: SharedMapInput) {
        let baiduURL = input.urls.first { MapShareCoordinateParser.provider(for: $0) == .baidu }
            ?? input.texts.compactMap(Self.firstURL(in:)).first { MapShareCoordinateParser.provider(for: $0) == .baidu }

        if let baiduURL {
            resolveBaiduWithWebView(baiduURL)
        } else {
            showError(NSLocalizedString("Could not extract coordinates from this map link locally.", comment: "Share extension local-only coordinate failure"))
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private func resolveBaiduWithWebView(_ url: URL) {
        statusLabel.text = NSLocalizedString("Resolving Baidu map page locally…", comment: "Baidu WebKit local fallback status")
        let resolver = BaiduWebViewCoordinateResolver()
        baiduResolver = resolver
        resolver.resolve(url, in: view) { [weak self, weak resolver] coordinate in
            guard let self else { return }
            let diagnostic = resolver?.diagnosticSummary ?? "Baidu debug: resolver released"
            self.baiduResolver = nil
            if let coordinate {
                self.send(coordinate, source: "Local Baidu WebKit")
                return
            }

            let message = NSLocalizedString("Could not extract coordinates from this map link locally.", comment: "Share extension local-only coordinate failure")
            self.showError(message + "\n\n" + diagnostic)
        }
    }

    private func send(_ coordinate: MapShareCoordinate, source: String) {
        statusLabel.text = NSLocalizedString("Sending location to PlaceDrift…", comment: "Share extension sending status")
        let client = ShareBridgeClient()
        bridgeClient = client
        client.send(coordinate: coordinate, source: source) { [weak self] success in
            guard let self else { return }
            self.bridgeClient = nil
            if success {
                self.spinner.stopAnimating()
                self.statusLabel.text = String(
                    format: NSLocalizedString("Location sent to PlaceDrift. Parser: %@", comment: "Share extension success with parser source"),
                    source
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            } else {
                self.showError(NSLocalizedString("PlaceDrift is not reachable. Open PlaceDrift once, enable Maps sharing, and allow Always Location access.", comment: "Share extension bridge failure"))
            }
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.font = message.contains("Baidu debug:") ? .systemFont(ofSize: 13) : .preferredFont(forTextStyle: .body)
        statusLabel.text = message
        closeButton.isHidden = false
    }

    @objc private func closeTapped() {
        resolver = nil
        baiduResolver = nil
        bridgeClient?.cancel()
        bridgeClient = nil
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private final class ShareBridgeClient {
    private let queue = DispatchQueue(label: "com.xepes.placedrift.share-extension-client")
    private var connection: NWConnection?
    private var completion: ((Bool) -> Void)?
    private var finished = false
    private var didSend = false
    private var source = "Unknown"
    private var coordinate: MapShareCoordinate?
    private var portIndex = 0

    func send(coordinate: MapShareCoordinate, source: String, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        self.source = source
        self.coordinate = coordinate
        self.finished = false
        self.didSend = false
        self.portIndex = 0

        queue.async { [weak self] in
            self?.tryNextPort()
        }
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finish(false)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finished = true
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.completion = nil
        }
    }

    private func tryNextPort() {
        guard !finished, let coordinate else { return }
        guard portIndex < PlaceDriftShareProtocol.ports.count else {
            finish(false)
            return
        }

        let rawPort = PlaceDriftShareProtocol.ports[portIndex]
        guard let port = NWEndpoint.Port(rawValue: rawPort) else {
            portIndex += 1
            tryNextPort()
            return
        }

        didSend = false
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            switch state {
            case .ready:
                self.sendPayload(coordinate, over: connection)
            case .waiting, .failed:
                self.advance(from: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendPayload(_ coordinate: MapShareCoordinate, over connection: NWConnection) {
        guard !didSend, !finished else { return }
        didSend = true

        guard var data = try? JSONEncoder().encode(
            PlaceDriftShareProtocol.Payload(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                source: source
            )
        ) else {
            finish(false)
            return
        }
        data.append(0x0A)

        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            guard error == nil else {
                self.advance(from: connection)
                return
            }
            self.receiveAcknowledgement(from: connection)
        })
    }

    private func receiveAcknowledgement(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            guard
                error == nil,
                let data,
                let value = String(data: data, encoding: .utf8),
                value.hasPrefix("OK")
            else {
                self.advance(from: connection)
                return
            }
            self.finish(true)
        }
    }

    private func advance(from connection: NWConnection) {
        guard self.connection === connection, !finished else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        didSend = false
        portIndex += 1
        tryNextPort()
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(success)
        }
    }
}
