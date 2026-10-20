import Foundation
import StreamProtocol

@main
struct Checks {
    static var checks = 0
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()
    static func check(_ value: Bool) { checks += 1; precondition(value) }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }
    static func refuses<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws {
        check((try? decoder.decode(type, from: JSONSerialization.data(withJSONObject: value))) == nil)
    }
    static func main() throws {
        let id = AudioForwardingDeviceID(hex: String(repeating: "a", count: 64))!
        let generation = UUID()
        let credential = try AudioForwardingCredential(pairedDeviceId: id, pairingGeneration: generation,
            credential: String(repeating: "A", count: 43))
        let empty = try AudioForwardingSnapshot(revision: .init(2), intent: nil, binding: nil)
        let snapshotObject = try object(empty)
        check(Set(snapshotObject.keys) == ["schemaVersion", "revision", "intent", "binding"])
        check(snapshotObject["intent"] is NSNull && snapshotObject["binding"] is NSNull)
        _ = try decoder.decode(AudioForwardingSnapshot.self, from: encoder.encode(empty))
        let bootstrap = try AudioForwardingBootstrap(credential: credential,
            ownCursor: .init(intentRevision: .init(UInt64.max), bindingRevision: .init(0)), snapshot: empty)
        let bootObject = try object(bootstrap)
        check(Set(bootObject.keys) == ["credential", "ownCursor", "snapshot"])
        let cursor = bootObject["ownCursor"] as! [String: Any]
        check(cursor["intentRevision"] as? String == "18446744073709551615")
        check(cursor["bindingRevision"] as? String == "0")
        check(Set((bootObject["credential"] as! [String: Any]).keys) == ["pairedDeviceId", "pairingGeneration", "credential"])
        for bad in ["01", "-1", "18446744073709551616"] {
            var value = bootObject; var own = cursor; own["intentRevision"] = bad; value["ownCursor"] = own
            try refuses(AudioForwardingBootstrap.self, value)
        }
        var extraBoot = bootObject; extraBoot["devices"] = [:]; try refuses(AudioForwardingBootstrap.self, extraBoot)
        var extraCursor = cursor; extraCursor["otherDevice"] = "1"
        extraBoot = bootObject; extraBoot["ownCursor"] = extraCursor; try refuses(AudioForwardingBootstrap.self, extraBoot)
        for kind in [AudioForwardingCatalog.Principal.Kind.tailnet, .cable, .localNetwork] {
            for role in [AudioForwardingCatalog.Role.controlOnly, .viewer] {
                let catalog = try AudioForwardingCatalog(principal: .init(kind: kind, id: id, authorizationGeneration: generation),
                    role: role, bootstrap: bootstrap)
                let round = try decoder.decode(AudioForwardingCatalog.self, from: encoder.encode(catalog))
                check(round.principal.id == id && round.principal.authorizationGeneration == generation && round.role == role)
            }
        }
        let catalog = try AudioForwardingCatalog(principal: .init(kind: .tailnet, id: id, authorizationGeneration: generation),
            role: .controlOnly, bootstrap: bootstrap)
        let catalogObject = try object(catalog)
        for key in catalogObject.keys { var value = catalogObject; value.removeValue(forKey: key); try refuses(AudioForwardingCatalog.self, value) }
        var invalidCatalog = catalogObject; invalidCatalog["schemaVersion"] = 1; try refuses(AudioForwardingCatalog.self, invalidCatalog)
        invalidCatalog = catalogObject; invalidCatalog["role"] = "audioOwner"; try refuses(AudioForwardingCatalog.self, invalidCatalog)
        let principal = catalogObject["principal"] as! [String: Any]
        for (key, value) in [("id", String(repeating: "b", count: 64)), ("authorizationGeneration", UUID().uuidString),
                             ("kind", "claimed-device")] {
            var wrong = principal; wrong[key] = value; invalidCatalog = catalogObject; invalidCatalog["principal"] = wrong
            try refuses(AudioForwardingCatalog.self, invalidCatalog)
        }
        var extraPrincipal = principal; extraPrincipal["appKey"] = "unused"
        invalidCatalog = catalogObject; invalidCatalog["principal"] = extraPrincipal; try refuses(AudioForwardingCatalog.self, invalidCatalog)
        let remembered = try AudioForwardingSnapshot.Intent(pairedDeviceId: id, intentId: UUID(), intentRevision: .init(7),
            intentGeneration: UUID(), inputDesired: false, outputDesired: false)
        let off = try AudioForwardingSnapshot(revision: .init(9), intent: remembered, binding: nil)
        let offBootstrap = try AudioForwardingBootstrap(credential: credential,
            ownCursor: .init(intentRevision: .init(7), bindingRevision: .init(11)), snapshot: off)
        let offRound = try decoder.decode(AudioForwardingBootstrap.self, from: encoder.encode(offBootstrap))
        check(offRound.snapshot.intent?.inputDesired == false && offRound.snapshot.intent?.outputDesired == false)
        var wrongCursor = try object(offBootstrap); wrongCursor["ownCursor"] = ["intentRevision":"6", "bindingRevision":"11"]
        try refuses(AudioForwardingBootstrap.self, wrongCursor)
        let request = try AudioForwardingIntentRequest(pairedDeviceId: id, intentId: remembered.intentId,
            intentRevision: .init(7), action: .resume, inputDesired: false, outputDesired: false,
            expectedRevision: .init(9), transportId: UUID(), transportKind: .native, bindingRevision: .init(12))
        check(try object(request).count == 11)
        let observe = try AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        let submit = try AudioForwardingControl(requestID: UUID(), operation: .submit, intent: request)
        for control in [observe, submit] {
            let data = try encoder.encode(control), value = try object(control)
            check(Set(value.keys) == ["schemaVersion", "requestID", "operation", "intent"])
            check(try decoder.decode(AudioForwardingControl.self, from: data).operation == control.operation)
            for key in value.keys { var missing = value; missing.removeValue(forKey: key); try refuses(AudioForwardingControl.self, missing) }
            var extra = value; extra["role"] = "viewer"; try refuses(AudioForwardingControl.self, extra)
        }
        check(try object(observe)["intent"] is NSNull)
        var wrongControl = try object(observe); wrongControl["intent"] = try object(request); try refuses(AudioForwardingControl.self, wrongControl)
        wrongControl = try object(submit); wrongControl["intent"] = NSNull(); try refuses(AudioForwardingControl.self, wrongControl)
        wrongControl = try object(observe); wrongControl["operation"] = "start"; try refuses(AudioForwardingControl.self, wrongControl)
        wrongControl = try object(observe); wrongControl["schemaVersion"] = 2; try refuses(AudioForwardingControl.self, wrongControl)
        let accepted = AudioForwardingResult<AudioForwardingSnapshot>.accepted(off)
        let refused = AudioForwardingResult<AudioForwardingSnapshot>.refused(code: "remembered_device_superseded", snapshot: off)
        check(Set(try object(accepted).keys) == ["schemaVersion", "revision", "intent", "binding"])
        check(Set(try object(refused).keys) == ["state", "code", "snapshot"])
        let observed = try AudioForwardingState(requestID: observe.requestID, operation: .observe, catalog: catalog, result: nil)
        for state in [observed,
                      try AudioForwardingState(requestID: submit.requestID, operation: .submit, catalog: nil, result: accepted),
                      try AudioForwardingState(requestID: submit.requestID, operation: .submit, catalog: nil, result: refused)] {
            let value = try object(state)
            check(Set(value.keys) == ["schemaVersion", "requestID", "operation", "catalog", "result"])
            check(try decoder.decode(AudioForwardingState.self, from: encoder.encode(state)).requestID == state.requestID)
            check(state.operation == .observe ? value["result"] is NSNull : value["catalog"] is NSNull)
            for key in value.keys { var missing = value; missing.removeValue(forKey: key); try refuses(AudioForwardingState.self, missing) }
            var both = value; both["catalog"] = catalogObject; both["result"] = try object(accepted); try refuses(AudioForwardingState.self, both)
            var neither = value; neither["catalog"] = NSNull(); neither["result"] = NSNull(); try refuses(AudioForwardingState.self, neither)
        }
        var list = WindowList(macName: "합성 Mac", windows: [], active: .none)
        check(try object(list)["audioForwarding"] == nil)
        list.audioForwarding = catalog
        let listed = try decoder.decode(WindowList.self, from: encoder.encode(list))
        check(listed.audioForwarding?.principal.id == id)
        check(StreamMessageKind.forwardingControl.rawValue == 217 && StreamMessageKind.forwardingState.rawValue == 218)
        check(StreamMessage.clientPayloadLimit(for: .forwardingControl) == 4096)
        check(StreamMessage.hostPayloadLimit(for: .forwardingState) == 16384)
        check(StreamMessage.hostPayloadLimit(for: .forwardingControl) == -1)
        check(StreamMessage.clientPayloadLimit(for: .forwardingState) == -1)
        for kind in [StreamMessageKind.forwardingUplinkReserved, .forwardingDownlinkReserved] {
            check(StreamMessage.clientPayloadLimit(for: kind) == -1 && StreamMessage.hostPayloadLimit(for: kind) == -1)
        }
        print("공유 음성 DTO 왕복·거절 검사 \(checks)개 통과. 실제 미디어·기기 실행 없음.")
    }
}
