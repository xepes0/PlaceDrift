import Darwin
import Foundation
@preconcurrency import Libmihomo
@preconcurrency import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await startProbeTunnel()
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        LibmihomoStop()
        completionHandler()
    }

    private func startProbeTunnel() async throws {
        try await configureNetworkSettings()

        let fd = packetFlowFileDescriptor()
        guard fd > 0 else {
            throw ProbeTunnelError("Could not obtain the iOS utun file descriptor.")
        }

        let layout = try prepareRuntimeFiles()
        LibmihomoSetHomeDir(layout.root.path)
        LibmihomoSetRuntimeSettingsPath(layout.settings.path)
        LibmihomoSetProfilesDir(layout.profiles.path)
        LibmihomoSetProfileIndexPath(layout.index.path)
        LibmihomoSetCommandSocketPath("")
        LibmihomoSetControllerSocketPath("")

        var bridgeError: NSError?
        guard LibmihomoSetTunFd(Int(fd), &bridgeError) else {
            throw bridgeError ?? ProbeTunnelError("LibmihomoSetTunFd failed.")
        }

        bridgeError = nil
        guard LibmihomoStart(&bridgeError) else {
            throw bridgeError ?? ProbeTunnelError("LibmihomoStart failed.")
        }
    }

    private func configureNetworkSettings() async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")

        let ipv4 = NEIPv4Settings(
            addresses: ["198.18.0.1"],
            subnetMasks: ["255.255.0.0"]
        )
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")
        ]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        try await setTunnelNetworkSettings(settings)
    }

    private struct RuntimeLayout {
        let root: URL
        let profiles: URL
        let settings: URL
        let index: URL
    }

    private func prepareRuntimeFiles() throws -> RuntimeLayout {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("WLOCTransportProbe", isDirectory: true)
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profiles,
            withIntermediateDirectories: true
        )

        let profile = profiles.appendingPathComponent("probe.yaml")
        let index = profiles.appendingPathComponent("index.json")
        let settings = root.appendingPathComponent("runtime_settings.json")

        let yaml = """
        mode: rule
        log-level: debug
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver:
            - 1.1.1.1
        tun:
          enable: true
          stack: gvisor
          auto-route: false
          auto-detect-interface: false
          loopback-address:
            - 10.7.0.1
        """

        try Data(yaml.utf8).write(to: profile, options: .atomic)
        try Data(#"[{"id":"probe","fileName":"probe.yaml"}]"#.utf8)
            .write(to: index, options: .atomic)
        try Data(#"{"activeProfileID":"probe","disableExternalController":true}"#.utf8)
            .write(to: settings, options: .atomic)

        return RuntimeLayout(root: root, profiles: profiles, settings: settings, index: index)
    }

    private func packetFlowFileDescriptor() -> Int32 {
        let keyPaths = [
            "socket.fileDescriptor",
            "_socket.fileDescriptor",
            "socket._fileDescriptor",
            "_socket._fileDescriptor"
        ]

        for keyPath in keyPaths {
            let raw = packetFlow.value(forKeyPath: keyPath)
            let fd = (raw as? NSNumber)?.int32Value ?? (raw as? Int32) ?? 0
            if fd > 0 { return fd }
        }

        return findUtunFileDescriptor() ?? -1
    }

    private func findUtunFileDescriptor() -> Int32? {
        let afSystem: UInt8 = 32
        let afSysControl: UInt16 = 2
        let limit = Int32(getdtablesize())

        for fd in 0..<limit {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let result = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getpeername(fd, $0, &length)
                }
            }
            guard result == 0 else { continue }

            let family: UInt8 = withUnsafeBytes(of: storage) { $0[1] }
            guard family == afSystem else { continue }

            let systemAddress: UInt16 = withUnsafeBytes(of: storage) {
                $0.load(fromByteOffset: 2, as: UInt16.self)
            }
            if systemAddress == afSysControl { return fd }
        }
        return nil
    }
}

private struct ProbeTunnelError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
