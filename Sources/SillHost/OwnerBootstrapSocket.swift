import Foundation
import Network
import StreamProtocol

final class OwnerBootstrapSocket: @unchecked Sendable {
    struct Binding: Equatable, Sendable {
        let generation: UUID
        let fingerprint: Data
        let sourceIP: String
        let localIP: String
        let interface: String
    }

    let binding: Binding
    private let lock = NSLock()
    private var cancelled = false
    private let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    private let current: () -> Bool

    private init(binding: Binding, trust: TrustBox? = nil, current: @escaping () -> Bool) {
        self.binding = binding
        let epoch = trust?.snapshot.ownerBootstrapEpoch
        self.current = {
            if let trust {
                let snapshot = trust.snapshot
                guard snapshot.remoteAccess, snapshot.ownerBootstrapEpoch == epoch else { return false }
            }
            return current()
        }
    }

    static func capture(_ connection: NWConnection, trust: TrustBox) -> OwnerBootstrapSocket? {
        guard let binding = read(connection, generation: UUID()) else { return nil }
        return Self(binding: binding, trust: trust) { [weak connection] in
            guard let connection else { return false }
            return read(connection, generation: binding.generation) == binding
        }
    }

    private static func read(_ c: NWConnection, generation: UUID) -> Binding? {
        guard case .ready = c.state, c.currentPath?.status == .satisfied, RemoteTLS.negotiatedALPN(c) == OwnerMacBootstrap.alpn,
              let fingerprint = RemoteTLS.peerFingerprint(c), fingerprint.count == 32,
              let source = Door.source(of: c), source.scope == nil,
              let remote = TailnetDeviceAccess.numericSource(IPBytes.text(IPBytes.unmapped(source.bytes))),
              case .hostPort(let localHost, _)? = c.currentPath?.localEndpoint,
              let local = TailnetDeviceAccess.numericSource(StreamServer.addressText(localHost).text) else { return nil }
        return routeBinding(generation: generation, fingerprint: fingerprint, source: remote, local: local,
                            interfaces: InterfaceSnapshot.policyInterfaces(InterfaceSnapshot.read().filter(\.up)))
    }

    static func routeBinding(generation: UUID, fingerprint: Data, source: String, local: String,
                             interfaces: OriginPolicy.Interfaces) -> Binding? {
        guard fingerprint.count == 32,
              let remote = TailnetDeviceAccess.numericSource(source),
              let local = TailnetDeviceAccess.numericSource(local), remote != local,
              let interface = OriginPolicy.arrivalInterface(localAddress: local, scope: nil, interfaces: interfaces),
              interfaces.kind[interface] == .tunnel else { return nil }
        return Binding(generation: generation, fingerprint: fingerprint, sourceIP: remote, localIP: local, interface: interface)
    }

    var isLive: Bool {
        guard DispatchTime.now().uptimeNanoseconds < deadline, current() else { return false }
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && DispatchTime.now().uptimeNanoseconds < deadline
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    #if OWNER_BOOTSTRAP_CONTRACT
    static func fixture(binding: Binding, trust: TrustBox? = nil, current: @escaping () -> Bool = { true }) -> OwnerBootstrapSocket {
        Self(binding: binding, trust: trust, current: current)
    }
    #endif
}

enum OwnerBootstrapWire {
    static func accepts(_ request: PairRequest) -> Bool {
        request.v == OwnerMacBootstrap.requestVersion && request.method == OwnerMacBootstrap.method
            && request.proof.isEmpty && request.cable == nil
    }
}

extension HostIdentity {
    func ownerMacBootstrap(sensor: TailnetDeviceAccess, proof: TailnetDeviceAccess.Proof, remotePort: Int) -> OwnerMacBootstrap? {
        guard proof.binding == nil, sensor.isCurrent(proof), proof.localIPs.contains(proof.sourceIP) else { return nil }
        return OwnerMacBootstrap(macID: macID, fingerprint: Base64URL.encode(fingerprint),
                                 addresses: proof.localIPs, remotePort: remotePort)
    }
}
