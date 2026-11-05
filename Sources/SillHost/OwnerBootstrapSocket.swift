import Foundation
import Network
import CryptoKit
import StreamProtocol

final class OwnerBootstrapSocket: @unchecked Sendable {
    struct Binding: Equatable, Sendable {
        let generation: UUID
        let fingerprint: Data
        let sourceIP: String
        let localIP: String
        let interface: String
        var usb: USB? = nil
    }

    struct USB: Equatable, Sendable {
        let deviceID: String
        let plugSession: UInt64
    }

    enum Purpose { case bootstrap, session }
    enum Evidence: @unchecked Sendable {
        case tailnet(sensor: TailnetDeviceAccess, proof: TailnetDeviceAccess.Proof)
        case usb(USBRegistration)

        init(sensor: TailnetDeviceAccess, proof: TailnetDeviceAccess.Proof) {
            self = .tailnet(sensor: sensor, proof: proof)
        }

        var principal: String {
            switch self {
            case .tailnet(_, let proof): return proof.principal
            case .usb(let proof): return proof.principal
            }
        }

        var isFresh: Bool {
            switch self {
            case .tailnet(_, let proof): return proof.isUnexpired
            case .usb(let proof): return proof.active()
            }
        }

        func withCurrent(binding: Binding, _ action: () -> Bool) -> Bool {
            switch self {
            case .tailnet(let sensor, let proof):
                guard binding.usb == nil, proof.binding == binding, proof.sourceIP == binding.sourceIP,
                      proof.localIPs.contains(binding.localIP), !proof.localIPs.contains(binding.sourceIP) else { return false }
                return sensor.withCurrent(proof, action)
            case .usb(let proof):
                guard binding.usb != nil, proof.binding == binding, proof.active() else { return false }
                return action()
            }
        }
    }

    struct USBRegistration: @unchecked Sendable {
        fileprivate let binding: Binding
        fileprivate let principal: String
        fileprivate let active: () -> Bool
    }

    func registeredUSBEvidence(store: IdentityStore, identity: HostIdentity,
                               registry: OwnerBootstrapRegistry, devices: [PairedDevice]) -> Evidence? {
        guard purpose == .session, let usb = binding.usb, let candidate,
              let device = devices.first(where: { $0.fingerprintData == binding.fingerprint }),
              device.cableDevice == nil || device.cableDevice == usb.deviceID else { return nil }
        let fingerprint = Base64URL.encode(binding.fingerprint)
        let principal = candidate.principal
        let active = {
            guard let fresh = try? OwnerBootstrapRegistry.load(store: store, identity: identity),
                  let saved = try? store.loadPaired(), fresh == registry, saved == devices,
                  fresh.observation(principal: principal, fingerprint: fingerprint, paired: saved) == .active,
                  let confirmation = try? OwnerBootstrapRegistry.load(store: store, identity: identity),
                  let confirmed = try? store.loadPaired() else { return false }
            return fresh == confirmation && saved == confirmed
        }
        guard !Task.isCancelled, isLive, active(), isLive else { return nil }
        return .usb(USBRegistration(binding: binding, principal: principal, active: active))
    }

    let binding: Binding
    let purpose: Purpose
    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var consumed = false
    private var usbAdmissionLogged = false
    private var receiptConsumed = false
    private let deadline: UInt64
    private let current: () -> Bool
    private let trust: TrustBox?
    private let epoch: UUID?
    private let candidate: TrustSnapshot.OwnerCandidate?

    private init(binding: Binding, purpose: Purpose = .bootstrap, trust: TrustBox? = nil,
                 deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 10_000_000_000,
                 current: @escaping () -> Bool) {
        self.binding = binding
        self.purpose = purpose
        self.trust = trust
        self.deadline = deadline
        let snapshot = trust?.snapshot
        epoch = snapshot?.ownerBootstrapEpoch
        candidate = snapshot?.ownerCandidates[binding.fingerprint]
        self.current = current
    }

    static func capture(_ connection: NWConnection, trust: TrustBox, purpose: Purpose = .bootstrap,
                        deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 10_000_000_000) -> OwnerBootstrapSocket? {
        guard let binding = read(connection, generation: UUID(), purpose: purpose) else { return nil }
        return Self(binding: binding, purpose: purpose, trust: trust, deadline: deadline) { [weak connection] in
            guard let connection else { return false }
            return read(connection, generation: binding.generation, purpose: purpose) == binding
        }
    }

    private static func read(_ c: NWConnection, generation: UUID, purpose: Purpose) -> Binding? {
        let alpn = purpose == .bootstrap ? OwnerMacBootstrap.alpn : RemoteTLS.sessionALPN
        guard case .ready = c.state, c.currentPath?.status == .satisfied, RemoteTLS.negotiatedALPN(c) == alpn,
              let fingerprint = RemoteTLS.peerFingerprint(c), fingerprint.count == 32,
              let source = Door.source(of: c),
              case .hostPort(let localHost, _)? = c.currentPath?.localEndpoint else { return nil }
        let local = StreamServer.addressText(localHost)
        if let scope = source.scope {
            guard purpose == .session else { return nil }
            return usbRouteBinding(generation: generation, fingerprint: fingerprint, source: source.bytes,
                scope: scope, local: local.text, localScope: local.scope,
                entries: InterfaceSnapshot.read(), own: InterfaceSnapshot.ownAddresses(),
                cable: InterfaceSnapshot.readCable(scope))
        }
        return routeBinding(generation: generation, fingerprint: fingerprint,
                            source: IPBytes.text(IPBytes.unmapped(source.bytes)), local: local.text,
                            interfaces: InterfaceSnapshot.policyInterfaces(InterfaceSnapshot.read().filter(\.up)))
    }

    static func usbRouteBinding(generation: UUID, fingerprint: Data, source: [UInt8], scope: String?,
                                local: String, localScope: String?, entries: [InterfaceSnapshot.Entry],
                                own: Set<[UInt8]>, cable: InterfaceSnapshot.CableReading) -> Binding? {
        guard fingerprint.count == 32, let scope, scope == localScope,
              let localBytes = IPBytes.parse(local), localBytes.count == 16, IPBytes.isLinkLocal(localBytes),
              entries.contains(where: { $0.name == scope && $0.up && !$0.loopback && !$0.pointToPoint
                  && IPBytes.unscoped($0.address) == IPBytes.unscoped(localBytes) }),
              OriginPolicy.interfaceKind(name: scope) == .lan,
              cable.registered, !cable.deviceMode, let ancestry = cable.ancestry,
              let device = CableLink.device(source: source, scope: scope, ownAddresses: own, cables: [scope: ancestry]),
              let serial = device.serial, let session = device.session, session != 0 else { return nil }
        return Binding(generation: generation, fingerprint: fingerprint,
                       sourceIP: IPBytes.text(IPBytes.unscoped(source)), localIP: IPBytes.text(IPBytes.unscoped(localBytes)),
                       interface: scope, usb: USB(deviceID: CableLink.deviceID(serial: serial), plugSession: session))
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

    func usbSessionIsCurrent(in box: TrustBox, evidence: Evidence) -> Bool {
        box.withDecision {
            lock.lock(); defer { lock.unlock() }
            let snapshot = box.snapshot
            guard purpose == .session, binding.usb != nil, consumed, !cancelled,
                  trust === box, snapshot.remoteAccess, snapshot.ownerBootstrapEpoch == epoch,
                  let candidate, snapshot.ownerCandidates[binding.fingerprint] == candidate,
                  evidence.principal == candidate.principal, current() else { return false }
            return evidence.withCurrent(binding: binding) {
                let latest = box.snapshot
                return current() && !cancelled && latest.remoteAccess && latest.ownerBootstrapEpoch == epoch
                    && latest.ownerCandidates[binding.fingerprint] == candidate
            }
        }
    }

    func takeUSBAdmissionLog() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard consumed, !usbAdmissionLogged, let usb = binding.usb else { return nil }
        usbAdmissionLogged = true
        let hash = SHA256.hash(data: binding.fingerprint).map { String(format: "%02x", $0) }.joined()
        return "ownerUSB phase=admitted interface=\(binding.interface) socketGeneration=\(binding.generation) plugSession=\(usb.plugSession) tlsFingerprintSHA256=\(hash)"
    }

    func permitsSession(at door: DoorPolicy.Door) -> Bool {
        purpose == .session && (binding.usb == nil || door == .remote)
    }

    var isLive: Bool {
        if let trust { return trust.withDecision { live(snapshot: trust.snapshot) } }
        return live(snapshot: nil)
    }

    private func live(snapshot: TrustSnapshot?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveLocked(snapshot: snapshot)
    }

    private func liveLocked(snapshot: TrustSnapshot?) -> Bool {
        if let epoch {
            guard let snapshot, snapshot.remoteAccess, snapshot.ownerBootstrapEpoch == epoch else { return false }
        }
        return !cancelled && current() && DispatchTime.now().uptimeNanoseconds < deadline
    }

    func cancel() {
        let cancel = { self.lock.lock(); self.cancelled = true; self.lock.unlock() }
        if let trust { trust.withDecision(cancel) } else { cancel() }
    }

    func decide(in box: TrustBox, evidence: Evidence, _ action: (TrustSnapshot) -> Bool) -> Bool {
        box.withDecision {
            lock.lock(); defer { lock.unlock() }
            let snapshot = box.snapshot
            guard trust == nil || trust === box, liveLocked(snapshot: snapshot),
                  !Task.isCancelled else { return false }
            return evidence.withCurrent(binding: binding) {
                guard liveLocked(snapshot: box.snapshot), !Task.isCancelled else { return false }
                return action(snapshot)
            }
        }
    }

    func issueReceipt(in box: TrustBox, evidence: Evidence,
                      valid: (TrustSnapshot) -> Bool, issue: () throws -> PairResult) -> PairResult? {
        box.withDecision {
            lock.lock()
            guard purpose == .bootstrap, binding.usb == nil, case .tailnet(let sensor, let proof) = evidence,
                  !receiptConsumed, trust == nil || trust === box else {
                lock.unlock(); return nil
            }
            receiptConsumed = true
            lock.unlock()
            func currentEvidence() -> Bool {
                live(snapshot: box.snapshot) && proof.binding == binding
                    && proof.sourceIP == binding.sourceIP
                    && proof.localIPs.contains(binding.localIP)
                    && !proof.localIPs.contains(binding.sourceIP)
                    && sensor.isCurrent(proof) && !Task.isCancelled
            }
            guard currentEvidence(), valid(box.snapshot), currentEvidence(), let signed = try? issue(),
                  valid(box.snapshot), currentEvidence() else { return nil }
            return signed
        }
    }

    func admit(in box: TrustBox, evidence: Evidence?, allowed: (TrustSnapshot) -> Bool = { _ in true },
               serve: (TrustSnapshot) -> Void) -> Bool {
        guard purpose == .session, let evidence, let candidate else { return false }
        return decide(in: box, evidence: evidence) { snapshot in
            guard !consumed, snapshot.remoteAccess, snapshot.ownerCandidates[binding.fingerprint] == candidate,
                  evidence.principal == candidate.principal, allowed(snapshot), evidence.isFresh,
                  liveLocked(snapshot: box.snapshot), !Task.isCancelled,
                  box.snapshot.ownerCandidates[binding.fingerprint] == candidate else { return false }
            consumed = true
            box.authorizeOwner(binding.fingerprint)
            serve(box.snapshot)
            return true
        }
    }

    #if OWNER_BOOTSTRAP_CONTRACT
    static func fixture(binding: Binding, trust: TrustBox? = nil, purpose: Purpose = .bootstrap,
                        deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 10_000_000_000,
                        current: @escaping () -> Bool = { true }) -> OwnerBootstrapSocket {
        Self(binding: binding, purpose: purpose, trust: trust, deadline: deadline, current: current)
    }
    #endif
}

enum OwnerBootstrapWire {
    static func decode(_ data: Data) -> PairRequest? {
        guard !data.isEmpty, data.count <= StreamMessage.maxPairingPayload,
              (try? LocalAudioRelayJSON.validate(data)) != nil else { return nil }
        return Wire.decode(PairRequest.self, from: data)
    }

    static func accepts(_ request: PairRequest) -> Bool {
        request.v == OwnerMacBootstrap.requestVersion && request.method == OwnerMacBootstrap.method
            && request.proof.isEmpty && request.cable == nil
    }
}

extension HostIdentity {
    func ownerMacBootstrap(sensor: TailnetDeviceAccess, profile: TailnetDeviceAccess.PublicProfile, remotePort: Int) -> OwnerMacBootstrap? {
        guard sensor.isCurrent(profile) else { return nil }
        return OwnerMacBootstrap(macID: macID, fingerprint: Base64URL.encode(fingerprint),
                                 addresses: profile.localIPs, remotePort: remotePort)
    }
}
