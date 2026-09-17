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
    private var workerResolver: WLOCWorkerCoordinateResolver?
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
        // Build 11 is deliberately local-first. Most WLOC /api/parse behavior is
        // already mirrored by MapShareCoordinateParser + MapShareRedirectResolver.
        // The Cloudflare Worker is kept only as the final compatibility fallback.
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
            resolveBaiduWithWebView(baiduURL, originalInput: input)
        } else {
            resolveWithWorkerFallback(input)
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private func resolveBaiduWithWebView(_ url: URL, originalInput: SharedMapInput) {
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

            // Dynamic Baidu pages can still change their script/API shape. Keep the
            // user's Worker as the last fallback instead of making it a dependency.
            self.resolveWithWorkerFallback(originalInput, diagnostic: diagnostic)
        }
    }

    private func resolveWithWorkerFallback(_ input: SharedMapInput, diagnostic: String? = nil) {
        let raw = input.combinedText
        guard !raw.isEmpty else {
            var message = NSLocalizedString("Could not extract coordinates from this map link.", comment: "Share extension coordinate failure")
            if let diagnostic, !diagnostic.isEmpty {
                message += "\n\n" + diagnostic
            }
            showError(message)
            return
        }

        statusLabel.text = NSLocalizedString("Local parsing failed; trying WLOC Worker…", comment: "WLOC worker last fallback status")
        let worker = WLOCWorkerCoordinateResolver()
        workerResolver = worker
        worker.resolve(rawSharedInput: raw) { [weak self] coordinate in
            guard let self else { return }
            self.workerResolver = nil
            if let coordinate {
                self.send(coordinate, source: "WLOC Worker fallback")
                return
            }

            var message = NSLocalizedString("Could not extract coordinates from this map link.", comment: "Share extension coordinate failure")
            if let diagnostic, !diagnostic.isEmpty {
                message += "\n\n" + diagnostic
            }
            self.showError(message)
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
        workerResolver?.cancel()
        baiduResolver = nil
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

    func send(coordinate: MapShareCoordinate, source: String, completion: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: PlaceDriftShareProtocol.port) else {
            completion(false)
            return
        }

        self.completion = completion
        self.source = source
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
