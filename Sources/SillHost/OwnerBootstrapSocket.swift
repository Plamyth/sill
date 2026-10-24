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

    enum Purpose { case bootstrap, session }
    struct Evidence: Sendable {
        let sensor: TailnetDeviceAccess
        let proof: TailnetDeviceAccess.Proof
    }

    let binding: Binding
    let purpose: Purpose
    private let lock = NSLock()
    private var cancelled = false
    private var consumed = false
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
                  evidence.proof.binding == binding, evidence.proof.sourceIP == binding.sourceIP,
                  evidence.proof.localIPs.contains(binding.localIP), !evidence.proof.localIPs.contains(binding.sourceIP) else { return false }
            return evidence.sensor.withCurrent(evidence.proof) {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                return action(snapshot)
            }
        }
    }

    func issueReceipt(in box: TrustBox, evidence: Evidence,
                      valid: (TrustSnapshot) -> Bool, issue: () throws -> PairResult) -> PairResult? {
        box.withDecision {
            lock.lock()
            guard purpose == .bootstrap, !receiptConsumed, trust == nil || trust === box else {
                lock.unlock(); return nil
            }
            // 결과 불명확·서명 실패도 같은 연결의 발급 기회를 소모한다.
            receiptConsumed = true
            lock.unlock()
            func currentEvidence() -> Bool {
                live(snapshot: box.snapshot) && evidence.proof.binding == binding
                    && evidence.proof.sourceIP == binding.sourceIP
                    && evidence.proof.localIPs.contains(binding.localIP)
                    && !evidence.proof.localIPs.contains(binding.sourceIP)
                    && evidence.sensor.isCurrent(evidence.proof) && !Task.isCancelled
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
                  evidence.proof.principal == candidate.principal, allowed(snapshot),
                  DispatchTime.now().uptimeNanoseconds < deadline, evidence.proof.isUnexpired else { return false }
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
    func ownerMacBootstrap(sensor: TailnetDeviceAccess, proof: TailnetDeviceAccess.Proof, remotePort: Int) -> OwnerMacBootstrap? {
        guard proof.binding == nil, sensor.isCurrent(proof), proof.localIPs.contains(proof.sourceIP) else { return nil }
        return OwnerMacBootstrap(macID: macID, fingerprint: Base64URL.encode(fingerprint),
                                 addresses: proof.localIPs, remotePort: remotePort)
    }
}
