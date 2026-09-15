import Foundation
import LibVpnCore
import NetworkExtension

class PacketTunnelProvider: ExtensionProvider {
    private let wlocBridge = WLOCTunnelBridge()

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        if wlocBridge.handles(messageData) {
            return await wlocBridge.handle(messageData)
        }
        return await super.handleAppMessage(messageData)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // Best effort: clear LocationSimulation before the VPN extension exits.
        wlocBridge.shutdown(timeoutSeconds: 3)
        super.stopTunnel(with: reason, completionHandler: completionHandler)
    }
}
