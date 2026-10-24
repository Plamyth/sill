#if os(iOS)
import Foundation
import Network
import Security
import StreamProtocol

extension StreamClient {
    private func ownerEnrollmentContext() -> (IPadEnrollmentProtocol.Binding, OwnerMacBootstrap, RemoteIdentity, ObjectIdentifier)? {
        guard appInForeground, connected, let connection, case .ready = connection.state, let id = session?.macID,
              let saved = savedMacs.first(where: { $0.macID == id }), saved.revoked != true, saved.newKey != true,
              saved.homeTLS == true, let pin = saved.fingerprintData,
              RemoteTLS.negotiatedALPN(connection) == RemoteTLS.sessionALPN,
              RemoteTLS.peerFingerprint(connection) == pin,
              let url = Bundle.main.url(forResource: OwnerMacBootstrap.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let profile = OwnerMacBootstrap.decodeResource(data), profile.macID == id, profile.fingerprintData == pin,
              let identity = DeviceIdentity.existing(), let publicKey = SecKeyCopyPublicKey(identity.privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, point.count == 65,
              let binding = try? IPadEnrollmentProtocol.Binding(macID: id, hostPin: pin, deviceSPKI: SPKI.der(point: point)),
              binding.deviceFingerprint == identity.fingerprint else { return nil }
        return (binding, profile, identity, ObjectIdentifier(connection))
    }

    func cancelOwnerEnrollment() {
        let previous = ownerEnrollment; ownerEnrollment = nil; ownerEnrollmentPeer = nil
        previous?.cancel()
    }

    func ownerEnrollmentTrustChanged() {
        guard let enrollment = ownerEnrollment else {
            if connected { resumeOwnerEnrollment() }
            return
        }
        guard let (binding, _, _, peer) = ownerEnrollmentContext(), enrollment.binding == binding, ownerEnrollmentPeer == peer else {
            cancelOwnerEnrollment(); return
        }
    }

    func resumeOwnerEnrollment() {
        guard let (binding, profile, identity, peer) = ownerEnrollmentContext() else { cancelOwnerEnrollment(); return }
        if ownerEnrollment?.binding != binding || ownerEnrollmentPeer != peer {
            cancelOwnerEnrollment()
            let store = IPadEnrollmentStore(deviceID: binding.deviceID)
            let current = { [weak self] () -> Bool in
                guard let context = self?.ownerEnrollmentContext() else { return false }
                return context.0 == binding && context.1 == profile && context.3 == peer
            }
            let io = IPadDeviceEnrollment.IO(load: { try store.load() }, compareAndSwap: { try store.compareAndSwap($0, $1) },
                post: { route, body, done in
                    guard current() else { done(.failure(IPadEnrollmentFailure.stale)); return {} }
                    return IPadEnrollmentHTTPPost.post(route, body: body, done: done)
                }, ownerReceipt: { [weak self] challenge, done in
                    guard let self, current() else { done(.failure(IPadEnrollmentFailure.stale)); return {} }
                    let transport = IPadOwnerReceiptTransport(queue: self.queue, profile: profile, identity: identity, binding: binding, current: current)
                    transport.start(challenge, name: "CCR iPad", model: ClientStatsReporter.hardwareIdentifier, done: done)
                    return { transport.cancel() }
                }, sign: { message in
                    guard current(), let existing = DeviceIdentity.existing(), existing.fingerprint == binding.deviceFingerprint,
                          let signature = SecKeyCreateSignature(existing.privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?,
                          current() else { throw IPadEnrollmentFailure.stale }
                    return signature
                }, current: current, now: { Int64(Date().timeIntervalSince1970 * 1000) })
            ownerEnrollmentPeer = peer
            let refusals = ownerEnrollmentRefusals[binding] ?? IPadDeviceEnrollment.Refusals()
            ownerEnrollmentRefusals[binding] = refusals
            ownerEnrollment = IPadDeviceEnrollment(binding: binding, io: io, refusals: refusals)
        }
        if let enrollment = ownerEnrollment {
            enrollment.ensure(ownerEnrollmentCompletion(enrollment) { _ in })
        }
    }

    private func ownerEnrollmentCompletion(_ enrollment: IPadDeviceEnrollment,
                                           done: @escaping IPadDeviceEnrollment.Completion) -> IPadDeviceEnrollment.Completion {
        guard let (binding, profile, _, peer) = ownerEnrollmentContext() else {
            return { _ in done(.failure(IPadEnrollmentFailure.stale)) }
        }
        var completed = false
        return { [weak self, weak enrollment] result in
            guard !completed else { return }; completed = true
            guard case .failure = result, let self, let enrollment,
                  self.ownerEnrollment === enrollment, enrollment.phase == .renewalRequired,
                  let (currentBinding, currentProfile, _, currentPeer) = self.ownerEnrollmentContext(),
                  currentBinding == binding, currentProfile == profile, currentPeer == peer else { done(result); return }
            enrollment.trustedRenew(done)
        }
    }

    func ownerEnrollmentAuthorizedRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        guard let (binding, _, _, peer) = ownerEnrollmentContext(), let enrollment = ownerEnrollment,
              enrollment.binding == binding, ownerEnrollmentPeer == peer else { throw IPadEnrollmentFailure.stale }
        return try enrollment.authorizedRequest(path: path, method: method, body: body)
    }

    var ownerEnrollmentCredential: IPadEnrollmentProtocol.Credential? {
        guard let (binding, _, _, peer) = ownerEnrollmentContext(), let enrollment = ownerEnrollment,
              enrollment.binding == binding, ownerEnrollmentPeer == peer else { return nil }
        return enrollment.credential
    }

    func ownerEnrollmentUnauthorized(_ refused: IPadEnrollmentProtocol.Credential, status: Int, body: Data,
                                     done: @escaping IPadDeviceEnrollment.Completion) {
        guard let enrollment = ownerEnrollment else { done(.failure(IPadEnrollmentFailure.stale)); return }
        enrollment.unauthorized(refused, status: status, body: body, done: ownerEnrollmentCompletion(enrollment, done: done))
    }

    func renewOwnerEnrollmentAfterConfirmedExpiry(_ done: @escaping IPadDeviceEnrollment.Completion) {
        guard let enrollment = ownerEnrollment else { done(.failure(IPadEnrollmentFailure.stale)); return }
        enrollment.trustedRenew(done)
    }
}
#endif
