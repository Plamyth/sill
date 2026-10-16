import Foundation
import StreamProtocol

extension StreamClient {
    func considerVisionCableBootstrap() {
        guard visionStartupStarted else { return }
        let context = VisionCableBootstrap<FoundMac>.Context(
            savedMacCount: savedMacs.count,
            occupied: connected || connection != nil || reconnect != nil || remoteDial != nil || pairingDial != nil || homeDialer != nil || pairing != .idle || homeAsk != nil,
            foreground: appInForeground && visionStartupForeground, permissionDenied: localNetworkDenied,
            candidates: macs.map { row in
                .init(row: row, service: row.endpoint.flatMap(Self.bonjourName), network: row.route == .network,
                      pairingRequired: row.door == .pairingRequired, wired: wiredDial(for: row) != nil)
            })
        visionCableBootstrap.consider(context) { row, pin in
            ask(row, savedID: nil, tagNamed: false, bootstrapPin: pin)
        }
    }

    func stopVisionCableBootstrap(_ reason: VisionCableBootstrap<FoundMac>.Reason) {
        if reason == .foregroundRequired && !visionStartupStarted { return }
        visionCableBootstrap.stop(reason)
        if homeAsk?.bootstrapPin != nil { cancelHomeAsk(idleStatus: false) }
    }
}
