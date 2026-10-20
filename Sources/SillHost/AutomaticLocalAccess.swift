import Foundation

enum AutomaticLocalAccess: Equatable, Sendable {
    case loopback
    case cable(deviceID: String)
    case localNetwork(interface: String)
    case directWireless(interface: String)

    static func resolve(remote: String, localAddress: String?, scope: String?,
                        interfaces: OriginPolicy.Interfaces, cables: [String: CableLink.Ancestry],
                        directWireless: Bool) -> Self? {
        guard let source = IPBytes.parse(remote) else { return nil }
        if IPBytes.isLoopback(source) { return .loopback }
        let arrival = OriginPolicy.arrivalInterface(localAddress: localAddress, scope: scope, interfaces: interfaces)
        guard let arrival, let kind = interfaces.kind[arrival] else { return nil }
        if case .lan = kind,
           let device = CableLink.device(source: source, scope: scope, ownAddresses: Set(interfaces.owner.keys), cables: cables),
           let serial = device.serial {
            return .cable(deviceID: CableLink.deviceID(serial: serial))
        }
        if case .peerToPeer = kind {
            return directWireless && IPBytes.isLinkLocal(source) ? .directWireless(interface: arrival) : nil
        }
        guard case .lan = kind,
              interfaces.prefixes.contains(where: {
                  $0.interface == arrival && IPBytes.contains(network: $0.network, bits: $0.bits, address: source)
              }) else { return nil }
        return .localNetwork(interface: arrival)
    }
}
