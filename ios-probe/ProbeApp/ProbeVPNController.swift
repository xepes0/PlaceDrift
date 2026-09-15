import Foundation
import NetworkExtension

@MainActor
final class ProbeVPNController: ObservableObject {
    static let providerBundleIdentifier = "com.xepes.wlocprobe.app.tunnel"

    @Published private(set) var statusText = "Not configured"
    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == Self.providerBundleIdentifier
            })
            isInstalled = manager != nil
            lastError = nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            statusText = "Load failed"
        }
    }

    func install() async {
        do {
            let current = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = current.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == Self.providerBundleIdentifier
            }) ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = "10.7.0.1 self-device probe"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "WLOC Transport Probe"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()

            self.manager = manager
            isInstalled = true
            lastError = nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() async {
        guard let manager else {
            lastError = "Install the VPN configuration first."
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            lastError = nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    private func refreshStatus() {
        guard let status = manager?.connection.status else {
            isRunning = false
            statusText = "Not configured"
            return
        }
        isRunning = status == .connected || status == .connecting || status == .reasserting
        switch status {
        case .invalid: statusText = "Invalid"
        case .disconnected: statusText = "Disconnected"
        case .connecting: statusText = "Connecting"
        case .connected: statusText = "Connected"
        case .reasserting: statusText = "Reasserting"
        case .disconnecting: statusText = "Disconnecting"
        @unknown default: statusText = "Unknown"
        }
    }
}
