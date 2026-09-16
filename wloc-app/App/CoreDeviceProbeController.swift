import Foundation
import Security
import SwiftUI
import UIKit

@MainActor
final class CoreDeviceProbeController: NSObject, ObservableObject {
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
    @Published private(set) var lastFailureStage = "None"
    @Published private(set) var lastError: String?

    private let publisher = PairingBonjourPublisher()
    private let browser = NetServiceBrowser()
    private var discoveredServices: [NetService] = []
    private var discoveryTimeout: Task<Void, Never>?
    private var pendingLocation: PendingLocation?

    private var pairingSession: OpaquePointer?
    private var locationSession: OpaquePointer?
    private var locationRunID: UUID?
    private var pairingRunID: UUID?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    override init() {
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
        publisher.onPublished = { [weak self] in
            self?.status = "Pairable host published. Open Settings › Privacy & Security › Developer Mode › Pair with Host."
        }
        publisher.onFailure = { [weak self] in
            self?.fail(stage: 9, message: "Bonjour publish failed. Allow Local Network access and try again.")
        }
    }

    var canStartLocation: Bool {
        hasPairingRecord && !isPairing && !isDiscovering && locationSession == nil
    }

    func refreshPairingState() {
        hasPairingRecord = PairingRecordStore.load() != nil
    }

    func resetPairing() {
        guard !isPairing, locationSession == nil else { return }
        PairingRecordStore.delete()
        hasPairingRecord = false
        pairingPIN = nil
        status = "Pairing record removed"
        lastError = nil
        lastFailureStage = "None"
    }

    func startPairing() {
        guard !isPairing, locationSession == nil else { return }
        guard let session = wloc_pairing_session_create() else {
            fail(stage: 255, message: "Could not create pairing engine.")
            return
        }

        pairingSession = session
        isPairing = true
        pairingPIN = nil
        lastError = nil
        lastFailureStage = "None"
        status = "Starting on-device pairing…"
        beginBackgroundTask(name: "WLOC pairing")

        let runID = UUID()
        pairingRunID = runID
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
                pairingReadyCallback,
                pairingPINCallback,
                context,
                &result
            )
            let outcome = PairingOutcome(result: result, code: code)
            wloc_pairing_result_destroy(&result)

            DispatchQueue.main.async {
                wloc_pairing_session_destroy(session)
                let controller = Unmanaged<CoreDeviceProbeController>
                    .fromOpaque(context)
                    .takeRetainedValue()
                controller.finishPairing(outcome, runID: runID)
            }
        }
    }

    func cancelPairing() {
        guard let pairingSession else { return }
        status = "Cancelling pairing…"
        wloc_pairing_session_cancel(pairingSession)
        publisher.stop()
    }

    func setLocation(latitude: Double, longitude: Double) {
        let validation = wloc_coredevice_validate_coordinates(latitude, longitude)
        guard validation.code == 0 else {
            fail(stage: validation.failure_stage, message: "Invalid coordinates.")
            return
        }

        if let locationSession, isLocationActive {
            let result = wloc_location_session_update(locationSession, latitude, longitude)
            guard result == 0 else {
                fail(stage: 7, message: "Could not update the active location.")
                return
            }
            status = String(format: "Location updated: %.6f, %.6f", latitude, longitude)
            return
        }

        guard let record = PairingRecordStore.load() else {
            fail(stage: 1, message: "Pair this iPhone first.")
            return
        }
        guard !isDiscovering, locationSession == nil else { return }

        pendingLocation = PendingLocation(record: record, latitude: latitude, longitude: longitude)
        lastError = nil
        lastFailureStage = "None"
        pairingPIN = nil
        beginRemotePairingDiscovery()
    }

    func clearLocation() {
        discoveryTimeout?.cancel()
        browser.stop()
        isDiscovering = false
        pendingLocation = nil

        guard let locationSession else {
            status = "No active simulated location"
            return
        }
        status = "Clearing simulated location…"
        wloc_location_session_cancel(locationSession)
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
                lastFailureStage = "None"
                lastError = nil
            } catch {
                fail(stage: 1, message: "Pairing succeeded but Keychain save failed: \(error.localizedDescription)")
            }
        case .failure(let stage, let message):
            fail(stage: stage, message: message)
        }
    }

    fileprivate func publishPairing(_ advertisement: PairingAdvertisement) {
        guard isPairing else { return }
        publisher.publish(advertisement)
    }

    fileprivate func showPIN(_ pin: String) {
        guard isPairing else { return }
        pairingPIN = pin
        status = "Enter this PIN in Pair with Host: \(pin)"
    }

    private func beginRemotePairingDiscovery() {
        cleanupDiscovery()
        isDiscovering = true
        status = "Discovering this iPhone's RemotePairing service through Clash Mi…"
        browser.delegate = self
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        discoveryTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.isDiscovering else { return }
            self.cleanupDiscovery()
            self.pendingLocation = nil
            self.fail(stage: 2, message: "No matching RemotePairing service was found. Keep Clash Mi connected with loopback-address 10.7.0.1.")
        }
    }

    private func resolve(_ service: NetService) {
        guard isDiscovering else { return }
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 6)
        discoveredServices.append(service)
    }

    private func considerResolvedService(_ service: NetService) {
        guard isDiscovering, let pendingLocation else { return }
        guard service.port > 0, service.port <= Int(UInt16.max) else { return }
        guard
            let txt = service.txtRecordData(),
            let identifierData = NetService.dictionary(fromTXTRecord: txt)["identifier"],
            let authTagData = NetService.dictionary(fromTXTRecord: txt)["authTag"]
        else { return }

        let identifier = String(decoding: identifierData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }

        let matches = pendingLocation.record.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return false }
            return identifier.withCString { identifierCString in
                authTag.withCString { authTagCString in
                    wloc_pairing_record_matches_service(
                        base,
                        pendingLocation.record.count,
                        identifierCString,
                        authTagCString
                    ) == 1
                }
            }
        }
        guard matches else { return }

        let remote = RemoteService(
            port: UInt16(service.port),
            identifier: identifier,
            authTag: authTag
        )
        cleanupDiscovery()
        isDiscovering = false
        runLocationSession(pending: pendingLocation, remote: remote)
    }

    private func runLocationSession(pending: PendingLocation, remote: RemoteService) {
        guard let session = wloc_location_session_create() else {
            fail(stage: 255, message: "Could not create location engine.")
            return
        }

        locationSession = session
        isLocationActive = false
        status = "Connecting: Pair Verify → TLS-PSK → RSD → DVT…"
        beginBackgroundTask(name: "WLOC location probe")
        let runID = UUID()
        locationRunID = runID
        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = WLOCLocationResult()
            let code = pending.record.withUnsafeBytes { bytes -> Int32 in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 2 }
                return "10.7.0.1".withCString { peer in
                    remote.identifier.withCString { identifier in
                        remote.authTag.withCString { authTag in
                            wloc_location_session_run(
                                session,
                                base,
                                pending.record.count,
                                peer,
                                remote.port,
                                identifier,
                                authTag,
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
            wloc_location_result_destroy(&result)

            DispatchQueue.main.async {
                wloc_location_session_destroy(session)
                let controller = Unmanaged<CoreDeviceProbeController>
                    .fromOpaque(context)
                    .takeRetainedValue()
                controller.finishLocation(outcome, runID: runID)
            }
        }
    }

    fileprivate func nativeLocationStarted() {
        guard locationSession != nil else { return }
        isLocationActive = true
        status = "LocationSimulation active. Switch to Maps now to verify."
    }

    private func finishLocation(_ outcome: LocationOutcome, runID: UUID) {
        guard locationRunID == runID else { return }
        locationRunID = nil
        locationSession = nil
        isLocationActive = false
        pendingLocation = nil
        endBackgroundTask()

        switch outcome {
        case .success:
            status = "LocationSimulation cleared"
            lastFailureStage = "None"
            lastError = nil
        case .failure(let stage, let message):
            fail(stage: stage, message: message)
        }
    }

    private func cleanupDiscovery() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        browser.stop()
        for service in discoveredServices {
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        discoveredServices.removeAll()
        isDiscovering = false
    }

    private func fail(stage: UInt32, message: String) {
        lastFailureStage = FailureStageName.name(for: stage)
        lastError = message
        status = "Failed at \(lastFailureStage)"
    }

    private func beginBackgroundTask(name: String) {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let pairingSession = self.pairingSession {
                    wloc_pairing_session_cancel(pairingSession)
                }
                if let locationSession = self.locationSession {
                    wloc_location_session_cancel(locationSession)
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

extension CoreDeviceProbeController: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        DispatchQueue.main.async { [weak self] in self?.resolve(service) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in self?.considerResolvedService(sender) }
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

    func publish(_ advertisement: PairingAdvertisement) {
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

private enum PairingOutcome: Sendable {
    case success(record: Data, name: String, model: String)
    case failure(stage: UInt32, message: String)

    init(result: WLOCPairingResult, code: Int32) {
        guard code == 0, let pointer = result.pairing_record, result.pairing_record_length > 0 else {
            let message = result.error_message.map { String(cString: $0) } ?? "Pairing failed."
            self = .failure(stage: result.failure_stage, message: message)
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
    case failure(stage: UInt32, message: String)

    init(result: WLOCLocationResult, code: Int32) {
        guard code == 0 else {
            let message = result.error_message.map { String(cString: $0) } ?? "Location session failed."
            self = .failure(stage: result.failure_stage, message: message)
            return
        }
        self = .success
    }
}

private enum FailureStageName {
    static func name(for value: UInt32) -> String {
        switch value {
        case 0: "None"
        case 1: "Pairing record"
        case 2: "Service identity"
        case 3: "Pair Verify"
        case 4: "TLS-PSK tunnel"
        case 5: "RSD"
        case 6: "DVT"
        case 7: "LocationSimulation"
        case 8: "Clear"
        case 9: "Pairing host"
        case 10: "Cancelled"
        default: "Internal"
        }
    }
}

private enum PairingRecordStore {
    private static let service = "com.xepes.wlocprobe.coredevice.pairing"
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

private let pairingReadyCallback: WLOCPairingReadyCallback = {
    context, serviceIdentifier, port, keys, values, count in
    guard let context, let serviceIdentifier, let keys, let values else { return }

    var records: [String: Data] = [:]
    for index in 0..<Int(count) {
        guard let key = keys[index], let value = values[index] else { continue }
        records[String(cString: key)] = Data(String(cString: value).utf8)
    }
    let advertisement = PairingAdvertisement(
        serviceIdentifier: String(cString: serviceIdentifier),
        port: Int32(port),
        textRecords: records
    )
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let controller = Unmanaged<CoreDeviceProbeController>.fromOpaque(pointer).takeUnretainedValue()
        controller.publishPairing(advertisement)
    }
}

private let pairingPINCallback: WLOCPairingPinCallback = { context, pin in
    guard let context, let pin else { return }
    let value = String(cString: pin)
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let controller = Unmanaged<CoreDeviceProbeController>.fromOpaque(pointer).takeUnretainedValue()
        controller.showPIN(value)
    }
}

private let locationStartedCallback: WLOCLocationStartedCallback = { context in
    guard let context else { return }
    let bits = UInt(bitPattern: context)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        let controller = Unmanaged<CoreDeviceProbeController>.fromOpaque(pointer).takeUnretainedValue()
        controller.nativeLocationStarted()
    }
}
