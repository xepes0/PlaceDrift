import Foundation
import NetworkExtension
import Security
import UIKit

@MainActor
final class WLOCMainBridge: NSObject {
    static let shared = WLOCMainBridge()

    private var pairingSession: OpaquePointer?
    private var pairingRunID: UUID?
    private var pairingCallbackURL: URL?
    private var pairingRequestID: String?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private let publisher = WLOCPairingBonjourPublisher()
    private var activeDiscovery: WLOCRemotePairingDiscovery?

    private override init() {
        super.init()
        publisher.onPublished = { [weak self] in
            self?.presentMessage(
                title: "WLOC pairing",
                message: "Pairable host published. Open Settings › Privacy & Security › Developer Mode › Pair with Host and select Clash Mi WLOC."
            )
        }
        publisher.onFailure = { [weak self] in
            self?.finishPairingFailure(stage: 9, errorCode: "bonjour_publish_failed")
        }
    }

    func handle(url: URL) -> Bool {
        guard let request = WLOCDeepLinkRequest.parse(url) else { return false }
        Task { @MainActor in
            await route(request)
        }
        return true
    }

    private func route(_ request: WLOCDeepLinkRequest) async {
        switch request.action {
        case .pair:
            startPairing(callback: request.callback, requestID: request.requestID)
        case .set:
            await setLocation(request)
        case .update:
            await updateLocation(request)
        case .clear:
            await simpleProviderCommand(request, messageID: WLOCProviderMessageID.clear)
        case .status:
            await simpleProviderCommand(request, messageID: WLOCProviderMessageID.status)
        }
    }

    private func setLocation(_ request: WLOCDeepLinkRequest) async {
        guard let latitude = request.latitude, let longitude = request.longitude else {
            finishCallback(request, ok: false, stage: 7, errorCode: "invalid_coordinates")
            return
        }
        guard let record = WLOCPairingRecordStore.load() else {
            finishCallback(request, ok: false, stage: 1, errorCode: "not_paired")
            presentMessage(title: "WLOC", message: "Pair this iPhone with Clash Mi WLOC first.")
            return
        }

        do {
            let service = try await discoverRemoteService(record: record)
            let payload = WLOCSetRequest(
                requestID: request.requestID ?? UUID().uuidString,
                pairingRecordBase64: record.base64EncodedString(),
                peerAddress: "10.7.0.1",
                remotePairingPort: service.port,
                serviceIdentifier: service.identifier,
                authTag: service.authTag,
                latitude: latitude,
                longitude: longitude
            )
            let response = try await WLOCProviderMessenger.send(
                messageID: WLOCProviderMessageID.set,
                payload: payload
            )
            finishCallback(request, response: response)
        } catch let error as WLOCBridgeError {
            finishCallback(request, ok: false, stage: error.stage, errorCode: error.code)
            presentMessage(title: "WLOC failed", message: error.code)
        } catch {
            finishCallback(request, ok: false, stage: 255, errorCode: "internal_error")
        }
    }

    private func updateLocation(_ request: WLOCDeepLinkRequest) async {
        guard let latitude = request.latitude, let longitude = request.longitude else {
            finishCallback(request, ok: false, stage: 7, errorCode: "invalid_coordinates")
            return
        }
        let payload = WLOCUpdateRequest(
            requestID: request.requestID ?? UUID().uuidString,
            latitude: latitude,
            longitude: longitude
        )
        do {
            let response = try await WLOCProviderMessenger.send(
                messageID: WLOCProviderMessageID.update,
                payload: payload
            )
            finishCallback(request, response: response)
        } catch let error as WLOCBridgeError {
            finishCallback(request, ok: false, stage: error.stage, errorCode: error.code)
        } catch {
            finishCallback(request, ok: false, stage: 255, errorCode: "internal_error")
        }
    }

    private func simpleProviderCommand(_ request: WLOCDeepLinkRequest, messageID: String) async {
        let payload = WLOCSimpleRequest(requestID: request.requestID ?? UUID().uuidString)
        do {
            let response = try await WLOCProviderMessenger.send(messageID: messageID, payload: payload)
            finishCallback(request, response: response)
        } catch let error as WLOCBridgeError {
            finishCallback(request, ok: false, stage: error.stage, errorCode: error.code)
        } catch {
            finishCallback(request, ok: false, stage: 255, errorCode: "internal_error")
        }
    }

    private func discoverRemoteService(record: Data) async throws -> WLOCRemoteService {
        if let activeDiscovery {
            activeDiscovery.cancel()
            self.activeDiscovery = nil
        }
        let discovery = WLOCRemotePairingDiscovery(record: record)
        activeDiscovery = discovery
        defer {
            if activeDiscovery === discovery { activeDiscovery = nil }
        }
        return try await discovery.run(timeoutSeconds: 15)
    }

    // MARK: - On-device pairing

    private func startPairing(callback: URL?, requestID: String?) {
        guard pairingSession == nil else {
            finishCallbackURL(callback, requestID: requestID, ok: false, stage: 9, errorCode: "pairing_busy")
            return
        }
        guard let session = wloc_pairing_session_create() else {
            finishCallbackURL(callback, requestID: requestID, ok: false, stage: 255, errorCode: "pairing_engine_unavailable")
            return
        }

        pairingSession = session
        pairingRunID = UUID()
        pairingCallbackURL = callback
        pairingRequestID = requestID
        beginBackgroundTask(name: "Clash Mi WLOC pairing")

        presentMessage(
            title: "WLOC pairing",
            message: "Starting pairable host… Keep Clash Mi in the app switcher, then open Developer Mode › Pair with Host."
        )

        let runID = pairingRunID!
        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = WLOCPairingResult()
            let code = wloc_pairing_session_run(
                session,
                wlocClashMiPairingReadyCallback,
                wlocClashMiPairingPINCallback,
                context,
                &result
            )
            let outcome = WLOCPairingOutcome(result: result, code: code)
            wloc_pairing_result_destroy(&result)

            DispatchQueue.main.async {
                wloc_pairing_session_destroy(session)
                let bridge = Unmanaged<WLOCMainBridge>.fromOpaque(context).takeRetainedValue()
                bridge.finishPairing(outcome, runID: runID)
            }
        }
    }

    func cancelPairing() {
        guard let pairingSession else { return }
        wloc_pairing_session_cancel(pairingSession)
        publisher.stop()
    }

    fileprivate func publishPairing(_ advertisement: WLOCPairingAdvertisement) {
        guard pairingSession != nil else { return }
        publisher.publish(advertisement)
    }

    fileprivate func showPairingPIN(_ pin: String) {
        guard pairingSession != nil else { return }
        presentMessage(
            title: "Pair with Host PIN",
            message: pin + "\n\nEnter this PIN in Settings › Developer Mode › Pair with Host."
        )
    }

    private func finishPairing(_ outcome: WLOCPairingOutcome, runID: UUID) {
        guard pairingRunID == runID else { return }
        pairingRunID = nil
        pairingSession = nil
        publisher.stop()
        endBackgroundTask()

        let callback = pairingCallbackURL
        let requestID = pairingRequestID
        pairingCallbackURL = nil
        pairingRequestID = nil

        switch outcome {
        case .success(let record, let name, let model):
            do {
                try WLOCPairingRecordStore.save(record)
                presentMessage(title: "WLOC paired", message: "Paired with \(name.isEmpty ? "this iPhone" : name) \(model).")
                finishCallbackURL(callback, requestID: requestID, ok: true, stage: nil, errorCode: nil)
            } catch {
                finishCallbackURL(callback, requestID: requestID, ok: false, stage: 1, errorCode: "pairing_store_failed")
            }
        case .failure(let stage, _):
            finishCallbackURL(callback, requestID: requestID, ok: false, stage: stage, errorCode: WLOCBridgeError.code(for: stage))
        }
    }

    private func finishPairingFailure(stage: UInt32, errorCode: String) {
        if let pairingSession { wloc_pairing_session_cancel(pairingSession) }
        finishCallbackURL(pairingCallbackURL, requestID: pairingRequestID, ok: false, stage: stage, errorCode: errorCode)
    }

    // MARK: - Callback

    private func finishCallback(_ request: WLOCDeepLinkRequest, response: WLOCProviderResponse) {
        finishCallbackURL(
            request.callback,
            requestID: request.requestID ?? response.requestID,
            ok: response.ok,
            stage: response.failureStage,
            errorCode: response.errorCode
        )
    }

    private func finishCallback(_ request: WLOCDeepLinkRequest, ok: Bool, stage: UInt32?, errorCode: String?) {
        finishCallbackURL(request.callback, requestID: request.requestID, ok: ok, stage: stage, errorCode: errorCode)
    }

    private func finishCallbackURL(_ callback: URL?, requestID: String?, ok: Bool, stage: UInt32?, errorCode: String?) {
        guard let callback else { return }
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if let requestID { items.append(URLQueryItem(name: "rid", value: requestID)) }
        items.append(URLQueryItem(name: "wloc_status", value: ok ? "ok" : "error"))
        if let stage { items.append(URLQueryItem(name: "wloc_stage", value: String(stage))) }
        if let errorCode { items.append(URLQueryItem(name: "wloc_error", value: errorCode)) }
        components?.queryItems = items
        guard let destination = components?.url else { return }
        UIApplication.shared.open(destination)
    }

    private func presentMessage(title: String, message: String) {
        guard let controller = UIApplication.shared.wlocTopViewController else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }

    private func beginBackgroundTask(name: String) {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.cancelPairing()
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private struct WLOCRemoteService: Sendable {
    let port: UInt16
    let identifier: String
    let authTag: String
}

@MainActor
private final class WLOCRemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let record: Data
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<WLOCRemoteService, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(record: Data) {
        self.record = record
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func run(timeoutSeconds: UInt64) async throws -> WLOCRemoteService {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutSeconds * NSEC_PER_SEC)
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(WLOCBridgeError(stage: 2, code: "service_not_found")))
            }
        }
    }

    func cancel() {
        finish(.failure(WLOCBridgeError(stage: 10, code: "cancelled")))
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            service.delegate = self
            service.includesPeerToPeer = true
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: 6)
            self.services.append(service)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in self?.consider(sender) }
    }

    private func consider(_ service: NetService) {
        guard !finished, service.port > 0, service.port <= Int(UInt16.max) else { return }
        guard let txtData = service.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard let identifierData = txt["identifier"], let authTagData = txt["authTag"] else { return }
        let identifier = String(decoding: identifierData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }

        let matches = record.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            return identifier.withCString { identifierCString in
                authTag.withCString { authTagCString in
                    wloc_pairing_record_matches_service(base, record.count, identifierCString, authTagCString) == 1
                }
            }
        }
        guard matches else { return }
        finish(.success(WLOCRemoteService(port: UInt16(service.port), identifier: identifier, authTag: authTag)))
    }

    private func finish(_ result: Result<WLOCRemoteService, Error>) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        for service in services {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        services.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let value): continuation?.resume(returning: value)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

private enum WLOCProviderMessenger {
    static func send<T: Encodable>(messageID: String, payload: T) async throws -> WLOCProviderResponse {
        let paramsData = try JSONEncoder().encode(payload)
        guard let params = String(data: paramsData, encoding: .utf8) else {
            throw WLOCBridgeError(stage: 255, code: "encode_failed")
        }
        let envelope = WLOCProviderEnvelope(messageId: messageID, messageParams: params)
        let data = try JSONEncoder().encode(envelope)
        let managers = try await loadManagers()
        guard let manager = managers.first(where: { $0.connection.status == .connected }),
              let session = manager.connection as? NETunnelProviderSession
        else {
            throw WLOCBridgeError(stage: 255, code: "clashmi_vpn_not_connected")
        }
        let responseData = try await send(data, through: session)
        guard let responseData else {
            throw WLOCBridgeError(stage: 255, code: "empty_provider_response")
        }
        return try JSONDecoder().decode(WLOCProviderResponse.self, from: responseData)
    }

    private static func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
    }

    private static func send(_ data: Data, through session: NETunnelProviderSession) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct WLOCBridgeError: Error {
    let stage: UInt32
    let code: String

    static func code(for stage: UInt32) -> String {
        switch stage {
        case 1: return "pairing_record_failed"
        case 2: return "service_identity_failed"
        case 3: return "pair_verify_failed"
        case 4: return "tls_psk_failed"
        case 5: return "rsd_failed"
        case 6: return "dvt_failed"
        case 7: return "location_failed"
        case 8: return "clear_failed"
        case 9: return "pairing_host_failed"
        case 10: return "cancelled"
        default: return "internal_error"
        }
    }
}

private enum WLOCPairingRecordStore {
    private static let service = "com.xepes.wloc.clashmi.pairing"
    private static let account = "device-pairing-record"

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct WLOCPairingAdvertisement: Sendable {
    let serviceIdentifier: String
    let port: Int32
    let textRecords: [String: Data]
}

@MainActor
private final class WLOCPairingBonjourPublisher: NSObject, NetServiceDelegate {
    var onPublished: (() -> Void)?
    var onFailure: (() -> Void)?
    private var service: NetService?

    func publish(_ advertisement: WLOCPairingAdvertisement) {
        stop()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: advertisement.serviceIdentifier,
            port: advertisement.port
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.textRecords))
        service.schedule(in: .main, forMode: .common)
        service.publish()
        self.service = service
    }

    func stop() {
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service?.delegate = nil
        service = nil
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in self?.onPublished?() }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }
}

private enum WLOCPairingOutcome: Sendable {
    case success(record: Data, name: String, model: String)
    case failure(stage: UInt32, message: String)

    init(result: WLOCPairingResult, code: Int32) {
        guard code == 0, let pointer = result.pairing_record, result.pairing_record_length > 0 else {
            self = .failure(
                stage: result.failure_stage,
                message: result.error_message.map { String(cString: $0) } ?? "Pairing failed."
            )
            return
        }
        self = .success(
            record: Data(bytes: pointer, count: result.pairing_record_length),
            name: result.device_name.map { String(cString: $0) } ?? "",
            model: result.device_model.map { String(cString: $0) } ?? ""
        )
    }
}

private let wlocClashMiPairingReadyCallback: WLOCPairingReadyCallback = {
    context, serviceIdentifier, port, keys, values, count in
    guard let context, let serviceIdentifier, let keys, let values else { return }
    var records: [String: Data] = [:]
    for index in 0..<Int(count) {
        guard let key = keys[index], let value = values[index] else { continue }
        records[String(cString: key)] = Data(String(cString: value).utf8)
    }
    let advertisement = WLOCPairingAdvertisement(
        serviceIdentifier: String(cString: serviceIdentifier),
        port: Int32(port),
        textRecords: records
    )
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let bridge = Unmanaged<WLOCMainBridge>.fromOpaque(context).takeUnretainedValue()
        bridge.publishPairing(advertisement)
    }
}

private let wlocClashMiPairingPINCallback: WLOCPairingPinCallback = { context, pin in
    guard let context, let pin else { return }
    let value = String(cString: pin)
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let bridge = Unmanaged<WLOCMainBridge>.fromOpaque(context).takeUnretainedValue()
        bridge.showPairingPIN(value)
    }
}

private extension UIApplication {
    var wlocTopViewController: UIViewController? {
        let window = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        if let navigation = controller as? UINavigationController { return navigation.visibleViewController ?? navigation }
        if let tab = controller as? UITabBarController { return tab.selectedViewController ?? tab }
        return controller
    }
}
