import Foundation
import Security
import StreamProtocol

/// 실제 owner/TLS admission과 registry 현재성은 호출자가 발급 직전에 확인해야 한다.
/// 이 signer는 키체인·시계·소켓·registry를 읽지 않는다.
package enum MobileEnrollmentSigner {
    package static func receipt(_ input: MobileEnrollment.ReceiptInput,
                                identity: HostIdentity) throws -> MobileEnrollment.Envelope {
        try sign(input.payload(), purpose: MobileEnrollment.purpose, host: input.host, identity: identity)
    }

    package static func hostIdentity(_ challenge: MobileEnrollment.HostChallenge,
                                     host: MobileEnrollment.HostProfile,
                                     identity: HostIdentity) throws -> MobileEnrollment.HostIdentityFrame {
        let payload = MobileEnrollment.HostIdentityPayload(challenge: challenge, host: host)
        return try MobileEnrollment.HostIdentityFrame(envelope:
            sign(payload, purpose: MobileEnrollment.hostIdentityPurpose, host: host, identity: identity))
    }

    package static func activeResult(_ observation: MobileEnrollment.ActiveResultPayload,
                                     challenge: MobileEnrollment.ActiveChallenge, host: MobileEnrollment.HostProfile,
                                     identity: HostIdentity, nowMilliseconds: Int64) throws -> MobileEnrollment.ActiveResultFrame {
        try observation.validate(challenge: challenge, host: host, nowMilliseconds: nowMilliseconds)
        return try MobileEnrollment.ActiveResultFrame(envelope:
            sign(observation, purpose: MobileEnrollment.activeResultPurpose, host: host, identity: identity))
    }

    private static func sign<T: Encodable>(_ payload: T, purpose: String, host: MobileEnrollment.HostProfile,
                                            identity: HostIdentity) throws -> MobileEnrollment.Envelope {
        guard identity.macID == host.macID, identity.fingerprint == host.fingerprint.bytes,
              let publicKey = SecKeyCopyPublicKey(identity.remote.privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              point.count == 65, point.first == 4, SPKI.der(point: point) == host.publicSPKIDER else {
            throw MobileEnrollment.Failure.identityMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= 16_384 else { throw MobileEnrollment.Failure.invalidFields }
        let message = Data((purpose + "\0").utf8) + bytes
        guard let signature = identity.signRecord(message), identity.verifyRecord(message, signature: signature) else {
            throw MobileEnrollment.Failure.invalidSignature
        }
        return MobileEnrollment.Envelope(payload: Base64URL.encode(bytes), signature: Base64URL.encode(signature),
                                         publicSPKI: Base64URL.encode(host.publicSPKIDER))
    }
}
