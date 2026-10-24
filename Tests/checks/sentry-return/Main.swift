import Foundation
import StreamProtocol
import CryptoKit

@main struct Checks {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
    static func main() throws {
        check(StreamMessageKind(rawValue: 223) != nil && StreamMessageKind(rawValue: 224) != nil,
              "새 복귀 계약의 223/224 kind가 기존 unknown 경로와 구분됨")
        check(StreamMessage.clientPayloadLimit(for: .sentryReturnRequest) == 4096 &&
            StreamMessage.hostPayloadLimit(for: .sentryReturnState) == 16384 &&
            StreamMessage.clientPayloadLimit(for: .sentryReturnState) == -1 &&
            StreamMessage.hostPayloadLimit(for: .sentryReturnRequest) == -1, "새 kind의 방향과 크기 제한")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("fixtures.json"))) as! [String: Any]
        for name in ["requestDeviceRaw", "requestMacRaw", "enrollRaw", "rotateRaw", "revokeRaw", "currentRaw", "cancelRaw", "proofRaw"] {
            let bytes = Data((f[name] as! String).utf8)
            let value = try SentryReturnControl.decodePayload(bytes)
            let roundtrip = try SentryReturnControl.decodePayload(value.encodedPayload())
            check(value == roundtrip, "공유 fixture 왕복 \(name)")
        }
        let request = try SentryReturnRequest(rawRequest: Data((f["requestDeviceRaw"] as! String).utf8))
        check(request.requestDigest == f["requestDeviceSHA256"] as? String, "원본 요청 바이트 SHA256 golden")
        let challengeBytes = try JSONSerialization.data(withJSONObject: f["challenge"]!)
        let challenge = try JSONDecoder().decode(SentryReturnChallenge.self, from: challengeBytes)
        let signed = try challenge.signingBytes()
        check(signed.base64EncodedString() == f["signingPayloadBase64"] as? String &&
            SentryReturnRequest.digest(signed) == f["signingBytesSHA256"] as? String, "Android와 Apple의 canonical 서명 바이트 golden")
        guard case .prove(_, _, let signature) = try SentryReturnControl.decodePayload(Data((f["proofRaw"] as! String).utf8)) else { fatalError() }
        let key = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: f["publicKeySPKIBase64"] as! String)!)
        let proof = try P256.Signing.ECDSASignature(derRepresentation: signature)
        check(key.isValidSignature(proof, for: signed), "고정 P256 DER proof를 실제 CryptoKit 검증")
        for name in ["pendingStateRaw", "completedStateRaw"] {
            let state = try SentryReturnState.decodePayload(Data((f[name] as! String).utf8))
            let decoded = try SentryReturnState.decodePayload(state.encodedPayload())
            check(state == decoded, "상태 fixture 왕복 \(name)")
        }
        let capability = try SentryReturnCapability.decodePayload(JSONSerialization.data(withJSONObject: f["capability"]!))
        check(capability.keyEnrollment == "macLocalRequired", "공유 capability는 키 변경에 Mac 인증 필수를 명시")
        let original = f["requestDeviceRaw"] as! String
        for bad in [String(original.dropLast()) + ",\"accepted\":true}",
                    String(original.dropLast()) + ",\"operation\":\"request\"}",
                    String(original.dropLast()) + ",\"oper\\u0061tion\":\"request\"}",
                    original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                    original.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                    original.replacingOccurrences(of: "\"deviceBoundKey\"", with: "null"),
                    String(repeating: " ", count: 4097) + original] {
            do { _ = try SentryReturnControl.decodePayload(Data(bad.utf8)); check(false, "잘못된 wire 거절") }
            catch { check(true, "중복·escaped 중복·unknown·잘못된 타입·상한 거절") }
        }
    }
}
