import Foundation

public struct OwnerEnrollmentRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let challenge: MobileEnrollment.InitialChallenge
    public let devicePublicKey: String

    public init(challenge: MobileEnrollment.InitialChallenge, devicePublicKey: String) throws {
        guard let bytes = Base64URL.decode(devicePublicKey), Base64URL.encode(bytes) == devicePublicKey,
              try MobileEnrollment.Fingerprint(spkiDER: bytes).hex == challenge.deviceId else {
            throw MobileEnrollment.Failure.invalidKey
        }
        schemaVersion = 1; self.challenge = challenge; self.devicePublicKey = devicePublicKey
    }

    public init(from decoder: Decoder) throws {
        let c = try strictOwnerFields(decoder, allowed: ["schemaVersion", "challenge", "devicePublicKey"])
        guard try c.decode(Int.self, forKey: .init("schemaVersion")) == 1 else {
            throw MobileEnrollment.Failure.invalidFields
        }
        let fields = try strictOwnerFields(c.superDecoder(forKey: .init("challenge")),
            allowed: ["schema", "challengeId", "nonce", "deviceId", "origin", "expiresAt"])
        guard try fields.decode(String.self, forKey: .init("schema")) == "ccr.device-challenge/v1" else {
            throw MobileEnrollment.Failure.invalidFields
        }
        let challenge = try MobileEnrollment.InitialChallenge(
            challengeId: fields.decode(String.self, forKey: .init("challengeId")),
            nonce: fields.decode(String.self, forKey: .init("nonce")),
            deviceId: fields.decode(String.self, forKey: .init("deviceId")),
            origin: fields.decode(String.self, forKey: .init("origin")),
            expiresAtMilliseconds: fields.decode(Int64.self, forKey: .init("expiresAt")))
        try self.init(challenge: challenge, devicePublicKey: c.decode(String.self, forKey: .init("devicePublicKey")))
    }
}

struct OwnerCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private func strictOwnerFields(_ decoder: Decoder, allowed: Set<String>) throws -> KeyedDecodingContainer<OwnerCodingKey> {
    let c = try decoder.container(keyedBy: OwnerCodingKey.self)
    guard Set(c.allKeys.map(\.stringValue)) == allowed else { throw MobileEnrollment.Failure.invalidFields }
    return c
}


extension MobileEnrollment.Envelope: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try strictOwnerFields(decoder, allowed: ["payload", "signature", "publicSPKI"])
        self.init(payload: try c.decode(String.self, forKey: .init("payload")),
                  signature: try c.decode(String.self, forKey: .init("signature")),
                  publicSPKI: try c.decode(String.self, forKey: .init("publicSPKI")))
        _ = try parts()
    }
}
