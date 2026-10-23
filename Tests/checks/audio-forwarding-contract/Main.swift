import Foundation
import StreamProtocol

@main
struct ForwardingChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let fingerprint = Data(repeating: 0xab, count: 32)
        let peer = AudioForwardingDeviceID(fingerprint: fingerprint)!
        precondition(peer.hex == String(repeating: "ab", count: 32))
        precondition(AudioForwardingDeviceID(fingerprint: Data(repeating: 0, count: 31)) == nil)
        func refuses<T: Decodable>(_ type: T.Type, _ value: Any) {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            precondition((try? decoder.decode(type, from: data)) == nil)
        }
        for text in ["00", "+1", "-1", "01", "1.0", " 1", "18446744073709551616"] {
            refuses(AudioForwardingRevision.self, text)
        }
        let maximum = try decoder.decode(AudioForwardingRevision.self, from: Data(#""18446744073709551615""#.utf8))
        precondition(maximum.value == UInt64.max)
        refuses(AudioForwardingDeviceID.self, String(repeating: "AB", count: 32))
        let intentID = "00112233-4455-6677-8899-aabbccddeeff"
        let transportID = "10112233-4455-6677-8899-aabbccddeeff"
        var request: [String: Any] = ["schemaVersion": 1, "pairedDeviceId": peer.hex,
            "intentId": intentID, "intentRevision": "1", "action": "resume", "inputDesired": true,
            "outputDesired": true, "expectedRevision": "0", "transportId": transportID,
            "transportKind": "native", "bindingRevision": "2"]
        let data = try JSONSerialization.data(withJSONObject: request)
        let intent = try decoder.decode(AudioForwardingIntentRequest.self, from: data)
        precondition(intent.action == .resume && intent.bindingRevision.value == 2 && intent.intentRevision.value == 1)
        precondition(intent.intentId == UUID(uuidString: intentID.uppercased()))
        request["unexpected"] = true
        refuses(AudioForwardingIntentRequest.self, request)
        request["unexpected"] = nil
        request["action"] = "stop"
        refuses(AudioForwardingIntentRequest.self, request)
        request["inputDesired"] = false; request["outputDesired"] = false
        let stopped = try decoder.decode(AudioForwardingIntentRequest.self, from: JSONSerialization.data(withJSONObject: request))
        precondition(stopped.action == .stop && !stopped.inputDesired && !stopped.outputDesired)
        request["bindingRevision"] = "0"
        refuses(AudioForwardingIntentRequest.self, request)

        let controller = "20112233-4455-6677-8899-aabbccddeeff"
        let privacy = "30112233-4455-6677-8899-aabbccddeeff"
        let nativeBoot = "40112233-4455-6677-8899-aabbccddeeff"
        let relayBoot = "50112233-4455-6677-8899-aabbccddeeff"
        var configuration: [String: Any] = ["controllerBootId": controller, "privacyGeneration": privacy,
            "registryRevision": "7", "members": [
                ["participantId": "s23.audio.relay", "bootId": relayBoot],
                ["participantId": "native.sill", "bootId": nativeBoot]]]
        let config = try decoder.decode(AudioForwardingConfiguration.self, from: JSONSerialization.data(withJSONObject: configuration))
        precondition(config.members.map(\.participantId) == ["native.sill", "s23.audio.relay"])
        var binding: [String: Any] = ["pairedDeviceId": peer.hex, "intentGeneration": intentID,
            "bindingEpoch": transportID, "transportId": transportID, "transportKind": "native",
            "operationId": controller, "phase": "quiescing", "configuration": configuration]
        let prepared = try decoder.decode(AudioForwardingBinding.self, from: JSONSerialization.data(withJSONObject: binding))
        let native = prepared.participantRequest(for: .native, budgetMilliseconds: 2000)!
        let relay = prepared.participantRequest(for: .relay, budgetMilliseconds: 2000)!
        precondition(native.operationId == relay.operationId && native.bootId == UUID(uuidString: nativeBoot))
        precondition(relay.bootId == UUID(uuidString: relayBoot) && native.privacyGeneration == UUID(uuidString: privacy))
        precondition(native.registryRevision == "7" && native.participantId != relay.participantId)
        precondition(prepared.participantRequest(for: .native, budgetMilliseconds: 0) == nil)
        binding["phase"] = "active"
        let active = try decoder.decode(AudioForwardingBinding.self, from: JSONSerialization.data(withJSONObject: binding))
        precondition(active.participantRequest(for: .native, budgetMilliseconds: 2000) == nil)
        let remembered: [String: Any] = ["pairedDeviceId": peer.hex, "intentId": intentID,
            "intentRevision": "1", "intentGeneration": intentID, "inputDesired": true,
            "outputDesired": true, "sentryDesired": true, "localMutedDesired": true]
        var snapshot: [String: Any] = ["schemaVersion": 1, "revision": "8", "intent": remembered, "binding": binding]
        func readSnapshot() throws -> AudioForwardingSnapshot {
            try decoder.decode(AudioForwardingSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot))
        }
        let connected = try readSnapshot()
        precondition(connected.binding?.phase == .active)
        snapshot["binding"] = NSNull()
        let disconnected = try readSnapshot()
        precondition(disconnected.binding == nil && disconnected.intent?.inputDesired == true &&
                     disconnected.intent?.outputDesired == true && disconnected.intent?.localMutedDesired == true)
        var invalidIntent = remembered
        invalidIntent["sentryDesired"] = false
        snapshot["intent"] = invalidIntent
        refuses(AudioForwardingSnapshot.self, snapshot)
        snapshot["intent"] = NSNull(); snapshot["binding"] = binding
        refuses(AudioForwardingSnapshot.self, snapshot)
        snapshot["intent"] = remembered
        var wrongBinding = binding
        wrongBinding["intentGeneration"] = relayBoot
        snapshot["binding"] = wrongBinding
        refuses(AudioForwardingSnapshot.self, snapshot)
        snapshot["binding"] = NSNull()
        let refused: [String: Any] = ["state": "refused", "code": "stale_transport_revision", "snapshot": snapshot]
        let refusal = try decoder.decode(AudioForwardingResult<AudioForwardingSnapshot>.self,
            from: JSONSerialization.data(withJSONObject: refused))
        guard case .refused(let code, let current) = refusal else { preconditionFailure("거절은 성공 응답이 아님") }
        precondition(code == "stale_transport_revision" && current.binding == nil)
        var malformedRefusal = refused
        malformedRefusal["state"] = "accepted"
        refuses(AudioForwardingResult<AudioForwardingSnapshot>.self, malformedRefusal)
        malformedRefusal = refused; malformedRefusal["code"] = "secret text"
        refuses(AudioForwardingResult<AudioForwardingSnapshot>.self, malformedRefusal)
        let accepted = try decoder.decode(AudioForwardingResult<AudioForwardingSnapshot>.self,
            from: JSONSerialization.data(withJSONObject: snapshot))
        guard case .accepted(let current) = accepted else { preconditionFailure("정상 원장을 거절로 오인") }
        precondition(current.revision.value == 8)
        var credential: [String: Any] = ["pairedDeviceId": peer.hex, "pairingGeneration": intentID,
            "credential": String(repeating: "a", count: 43)]
        let auth = try decoder.decode(AudioForwardingCredential.self,
            from: JSONSerialization.data(withJSONObject: credential))
        precondition(auth.pairedDeviceId == peer && auth.pairingGeneration == UUID(uuidString: intentID))
        credential["credential"] = "not a credential"
        refuses(AudioForwardingCredential.self, credential)
        let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
            callbacksDrained: true, buffersEmpty: true, workersExited: true)
        let receipt = LocalAudioParticipantReceipt(relay, state: .quiescent, facts: facts)
        let preparedResult = try decoder.decode(AudioForwardingResult<LocalAudioParticipantReceipt>.self,
            from: JSONEncoder().encode(receipt))
        guard case .accepted(let actualReceipt) = preparedResult else { preconditionFailure("종료 영수증은 요청 거절이 아님") }
        precondition(actualReceipt.proves(relay))
        binding["authenticated"] = true
        refuses(AudioForwardingBinding.self, binding)
        configuration["members"] = [["participantId": "native.sill", "bootId": nativeBoot]]
        refuses(AudioForwardingConfiguration.self, configuration)
        configuration["members"] = [["participantId": "native.sill", "bootId": nativeBoot], ["participantId": "native.sill", "bootId": relayBoot]]
        refuses(AudioForwardingConfiguration.self, configuration)
        print("입출력 계약의 ID·revision·명시적 OFF·전송 세대·등록부·기존 참가자 요청 연결 검증 통과")
        print("단순 decode를 인증이나 실제 미디어 입장 허용으로 취급하지 않음")
    }
}
