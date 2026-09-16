import Foundation
import Security
import SwiftUI
import UIKit

@MainActor
final class CoreDeviceController: NSObject, ObservableObject {
    private static let mapSharingPreferenceKey = "placedrift.maps-sharing.enabled"

    private struct PendingLocation {
        let record: Data
        let latitude: Double
        let longitude: Double
    }

    private struct RemoteService {
        let port: UInt16
        let identifier: String
        let authTag: String
    }

    @Published private(set) var status = "Ready"
    @Published private(set) var hasPairingRecord = PairingRecordStore.load() != nil
    @Published private(set) var pairingPIN: String?
    @Published private(set) var isPairing = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var isLocationActive = false
    @Published private(set) var lastError: String?
    @Published private(set) var isMapSharingEnabled = true
    @Published private(set) var shareBridgeReady = false
    @Published private(set) var backgroundKeepAliveState = BackgroundLocationKeepAlive.State.idle

    private let publisher = PairingBonjourPublisher()
    private let browser = NetServiceBrowser()
    private let backgroundKeepAlive = BackgroundLocationKeepAlive()
    private let shareBridge = PlaceDriftShareBridge()
    private var services: [NetService] = []
    private var discoveryTimeout: Task<Void, Never>?
    private var pendingLocation: PendingLocation?
    private var pairingSession: OpaquePointer?
    private var locationSession: OpaquePointer?
    private var locationRunID: UUID?
    private var pairingRunID: UUID?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    override init() {
        super.init()

        isMapSharingEnabled = UserDefaults.standard.object(forKey: Self.mapSharingPreferenceKey) as? Bool ?? true
        browser.delegate = self
        browser.includesPeerToPeer = true

        publisher.onPublished = { [weak self] in
            self?.status = "Pairable host published. Open Settings › Privacy & Security › Developer Mode › Pair with Host."
        }
        publisher.onFailure = { [weak self] in
            self?.fail("Bonjour publish failed. Allow Local Network access and try again.")
        }

        backgroundKeepAliveState = backgroundKeepAlive.state
        backgroundKeepAlive.onStateChange = { [weak self] state in
            self?.backgroundKeepAliveState = state
        }

        shareBridge.onReadyChange = { [weak self] ready in
            Task { @MainActor in
                self?.shareBridgeReady = ready
            }
        }
        shareBridge.onLocation = { [weak self] latitude, longitude in
            Task { @MainActor in
                guard let self else { return }
                NotificationCenter.default.post(
                    name: .placeDriftSetLocation,
                    object: nil,
                    userInfo: ["latitude": latitude, "longitude": longitude]
                )
                self.setLocation(latitude: latitude, longitude: longitude)
            }
        }

        reconcileMapSharing()
    }

    var canStartLocation: Bool {
        hasPairingRecord && !isPairing && !isDiscovering && locationSession == nil
    }

    var mapSharingReady: Bool {
        hasPairingRecord
            && isMapSharingEnabled
            && shareBridgeReady
            && backgroundKeepAliveState == .active
    }

    func refreshPairingState() {
        hasPairingRecord = PairingRecordStore.load() != nil
        reconcileMapSharing()
    }

    func setMapSharingEnabled(_ enabled: Bool) {
        guard isMapSharingEnabled != enabled else { return }
        isMapSharingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mapSharingPreferenceKey)
        reconcileMapSharing()
    }

    func resetPairing() {
        guard !isPairing, locationSession == nil else { return }
        PairingRecordStore.delete()
        hasPairingRecord = false
        pairingPIN = nil
        status = "Pairing record removed"
        lastError = nil
        reconcileMapSharing()
    }

    func startPairing() {
        guard !isPairing, locationSession == nil else { return }
        guard let session = placedrift_pairing_session_create() else {
            fail("Could not create pairing engine.")
            return
        }

        pairingSession = session
        isPairing = true
        pairingPIN = nil
        lastError = nil
        status = "Starting on-device pairing…"
        beginBackgroundTask(name: "PlaceDrift pairing")

        let runID = UUID()
        pairingRunID = runID
        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = PlaceDriftPairingResult()
            let code = placedrift_pairing_session_run(
                session,
                pairingReadyCallback,
                pairingPINCallback,
                context,
                &result
            )
            let outcome = PairingOutcome(result: result, code: code)
            placedrift_pairing_result_destroy(&result)

            DispatchQueue.main.async {
                placedrift_pairing_session_destroy(session)
                let controller = Unmanaged<CoreDeviceController>.fromOpaque(context).takeRetainedValue()
                controller.finishPairing(outcome, runID: runID)
            }
        }
    }

    func cancelPairing() {
        guard let pairingSession else { return }
        status = "Cancelling pairing…"
        placedrift_pairing_session_cancel(pairingSession)
        publisher.stop()
    }

    func setLocation(latitude: Double, longitude: Double) {
        let validation = placedrift_coredevice_validate_coordinates(latitude, longitude)
        guard validation.code == 0 else {
            fail("Invalid coordinates.")
            return
        }

        if let locationSession, isLocationActive {
            backgroundKeepAlive.start()
            guard placedrift_location_session_update(locationSession, latitude, longitude) == 0 else {
                fail("Could not update the active location.")
                return
            }
            status = String(format: "Location updated: %.6f, %.6f", latitude, longitude)
            return
        }

        guard let record = PairingRecordStore.load() else {
            fail("Pair this iPhone first.")
            return
        }
        guard !isDiscovering, locationSession == nil else { return }

        backgroundKeepAlive.start()
        pendingLocation = PendingLocation(record: record, latitude: latitude, longitude: longitude)
        pairingPIN = nil
        lastError = nil
        beginDiscovery()
    }

    func clearLocation() {
        stopDiscovery()
        pendingLocation = nil
        guard let locationSession else {
            status = "No active simulated location"
            reconcileBackgroundKeepAlive()
            return
        }
        status = "Clearing simulated location…"
        placedrift_location_session_cancel(locationSession)
    }

    private func finishPairing(_ outcome: PairingOutcome, runID: UUID) {
        guard pairingRunID == runID else { return }
        pairingRunID = nil
        pairingSession = nil
        isPairing = false
        publisher.stop()
        endBackgroundTask()

        switch outcome {
        case .success(let record, let name, let model):
            do {
                try PairingRecordStore.save(record)
                hasPairingRecord = true
                pairingPIN = nil
                status = "Paired: \(name.isEmpty ? "iPhone" : name) \(model)"
                lastError = nil
                reconcileMapSharing()
            } catch {
                fail("Pairing succeeded but Keychain save failed: \(error.localizedDescription)")
            }
        case .failure(let message):
            fail(message)
        }
    }

    fileprivate func publishPairing(_ ad: PairingAdvertisement) {
        guard isPairing else { return }
        publisher.publish(ad)
    }

    fileprivate func showPIN(_ pin: String) {
        guard isPairing else { return }
        pairingPIN = pin
        status = "Enter this PIN in Pair with Host: \(pin)"
    }

    private func beginDiscovery() {
        stopDiscovery()
        isDiscovering = true
        status = "Discovering this iPhone's RemotePairing service through Clash Mi…"
        reconcileBackgroundKeepAlive()
        browser.delegate = self
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        discoveryTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.isDiscovering else { return }
            self.stopDiscovery()
            self.pendingLocation = nil
            self.fail("No matching RemotePairing service was found. Keep Clash Mi connected with loopback-address 10.7.0.1.")
            self.reconcileBackgroundKeepAlive()
        }
    }

    private func resolve(_ service: NetService) {
        guard isDiscovering else { return }
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 6)
        services.append(service)
    }

    private func useResolved(_ service: NetService) {
        guard isDiscovering, let pendingLocation else { return }
        guard service.port > 0, service.port <= Int(UInt16.max) else { return }
        guard
            let txt = service.txtRecordData(),
            let identifierData = NetService.dictionary(fromTXTRecord: txt)["identifier"],
            let authTagData = NetService.dictionary(fromTXTRecord: txt)["authTag"]
        else { return }

        let identifier = String(decoding: identifierData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }

        let matches = pendingLocation.record.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            return identifier.withCString { id in
                authTag.withCString { tag in
                    placedrift_pairing_record_matches_service(base, pendingLocation.record.count, id, tag) == 1
                }
            }
        }
        guard matches else { return }

        let remote = RemoteService(port: UInt16(service.port), identifier: identifier, authTag: authTag)
        stopDiscovery()
        runLocationSession(pending: pendingLocation, remote: remote)
    }

    private func runLocationSession(pending: PendingLocation, remote: RemoteService) {
        guard let session = placedrift_location_session_create() else {
            fail("Could not create location engine.")
            reconcileBackgroundKeepAlive()
            return
        }

        locationSession = session
        isLocationActive = false
        status = "Connecting: Pair Verify → TLS-PSK → RSD → DVT…"
        backgroundKeepAlive.start()
        let runID = UUID()
        locationRunID = runID
        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = PlaceDriftLocationResult()
            let code = pending.record.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 2 }
                return "10.7.0.1".withCString { peer in
                    remote.identifier.withCString { id in
                        remote.authTag.withCString { tag in
                            placedrift_location_session_run(
                                session,
                                base,
                                pending.record.count,
                                peer,
                                remote.port,
                                id,
                                tag,
                                pending.latitude,
                                pending.longitude,
                                locationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let outcome = LocationOutcome(result: result, code: code)
            placedrift_location_result_destroy(&result)

            DispatchQueue.main.async {
                placedrift_location_session_destroy(session)
                let controller = Unmanaged<CoreDeviceController>.fromOpaque(context).takeRetainedValue()
                controller.finishLocation(outcome, runID: runID)
            }
        }
    }

    fileprivate func nativeLocationStarted() {
        guard locationSession != nil else { return }
        isLocationActive = true
        status = "LocationSimulation active. Share another place from Maps to switch instantly."
        reconcileBackgroundKeepAlive()
    }

    private func finishLocation(_ outcome: LocationOutcome, runID: UUID) {
        guard locationRunID == runID else { return }
        locationRunID = nil
        locationSession = nil
        isLocationActive = false
        pendingLocation = nil

        switch outcome {
        case .success:
            status = "LocationSimulation cleared"
            lastError = nil
        case .failure(let message):
            fail(message)
        }

        reconcileBackgroundKeepAlive()
    }

    private func reconcileMapSharing() {
        if hasPairingRecord && isMapSharingEnabled {
            shareBridge.start()
        } else {
            shareBridge.stop()
        }
        reconcileBackgroundKeepAlive()
    }

    private func reconcileBackgroundKeepAlive() {
        let needsBackgroundExecution = hasPairingRecord
            && (isMapSharingEnabled || isDiscovering || locationSession != nil)

        if needsBackgroundExecution {
            backgroundKeepAlive.start()
        } else {
            backgroundKeepAlive.stop()
        }
    }

    private func stopDiscovery() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        browser.stop()
        services.forEach {
            $0.stop()
            $0.remove(from: .main, forMode: .common)
            $0.delegate = nil
        }
        services.removeAll()
        isDiscovering = false
    }

    private func fail(_ message: String) {
        lastError = message
        status = "Failed"
    }

    private func beginBackgroundTask(name: String) {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let pairingSession = self.pairingSession {
                    placedrift_pairing_session_cancel(pairingSession)
                }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension CoreDeviceController: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        DispatchQueue.main.async { [weak self] in self?.resolve(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in self?.useResolved(sender) }
    }
}

fileprivate struct PairingAdvertisement: Sendable {
    let serviceIdentifier: String
    let port: Int32
    let textRecords: [String: Data]
}

@MainActor
private final class PairingBonjourPublisher: NSObject, NetServiceDelegate {
    var onPublished: (() -> Void)?
    var onFailure: (() -> Void)?
    private var service: NetService?

    func publish(_ ad: PairingAdvertisement) {
        stop()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: ad.serviceIdentifier,
            port: ad.port
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ad.textRecords))
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

private enum PairingOutcome: Sendable {
    case success(record: Data, name: String, model: String)
    case failure(message: String)

    init(result: PlaceDriftPairingResult, code: Int32) {
        guard code == 0, let pointer = result.pairing_record, result.pairing_record_length > 0 else {
            self = .failure(message: result.error_message.map { String(cString: $0) } ?? "Pairing failed.")
            return
        }
        self = .success(
            record: Data(bytes: pointer, count: result.pairing_record_length),
            name: result.device_name.map { String(cString: $0) } ?? "",
            model: result.device_model.map { String(cString: $0) } ?? ""
        )
    }
}

private enum LocationOutcome: Sendable {
    case success
    case failure(message: String)

    init(result: PlaceDriftLocationResult, code: Int32) {
        guard code == 0 else {
            self = .failure(message: result.error_message.map { String(cString: $0) } ?? "Location session failed.")
            return
        }
        self = .success
    }
}

private enum PairingRecordStore {
    private static let service = "com.xepes.placedrift.coredevice.pairing"
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
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

private let pairingReadyCallback: PlaceDriftPairingReadyCallback = {
    context, serviceIdentifier, port, keys, values, count in
    guard let context, let serviceIdentifier, let keys, let values else { return }

    var records: [String: Data] = [:]
    for index in 0..<Int(count) {
        guard let key = keys[index], let value = values[index] else { continue }
        records[String(cString: key)] = Data(String(cString: value).utf8)
    }

    let ad = PairingAdvertisement(
        serviceIdentifier: String(cString: serviceIdentifier),
        port: Int32(port),
        textRecords: records
    )
    let bits = UInt(bitPattern: context)

    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        Unmanaged<CoreDeviceController>.fromOpaque(pointer).takeUnretainedValue().publishPairing(ad)
    }
}

private let pairingPINCallback: PlaceDriftPairingPinCallback = { context, pin in
    guard let context, let pin else { return }
    let value = String(cString: pin)
    let bits = UInt(bitPattern: context)

    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        Unmanaged<CoreDeviceController>.fromOpaque(pointer).takeUnretainedValue().showPIN(value)
    }
}

private let locationStartedCallback: PlaceDriftLocationStartedCallback = { context in
    guard let context else { return }
    let bits = UInt(bitPattern: context)

    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        Unmanaged<CoreDeviceController>.fromOpaque(pointer).takeUnretainedValue().nativeLocationStarted()
    }
}
