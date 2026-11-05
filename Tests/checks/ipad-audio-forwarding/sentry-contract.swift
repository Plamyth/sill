import Foundation
import StreamProtocol
import LegacyForwarding

@main struct SentryContractCheck {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) { checks += 1; precondition(value, name) }
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            _ = try JSONDecoder().decode(LegacyForwarding.AudioForwardingState.self, from: data)
            preconditionFailure("exact82 must reproduce sentry=false invalidIntent")
        } catch LegacyForwarding.AudioForwardingFailure.invalidIntent {
            print("RED exact82 sentry=false intent25: invalidIntent reproduced")
        }
        let decoded = try JSONDecoder().decode(StreamProtocol.AudioForwardingState.self, from: data)
        check(decoded.catalog?.bootstrap.snapshot.revision.value == 25 && decoded.catalog?.bootstrap.snapshot.intent?.sentryDesired == false,
              "GREEN exact Host241 contract accepts false intent25 observe")
        let original = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let catalog = original["catalog"] as! [String:Any]
        let bootstrap = catalog["bootstrap"] as! [String:Any]
        let snapshot = bootstrap["snapshot"] as! [String:Any]
        let intent = snapshot["intent"] as! [String:Any]
        func changed(_ change: (inout [String:Any]) -> Void) throws -> Data {
            var c=original, cat=catalog, boot=bootstrap, snap=snapshot, i=intent
            change(&i); snap["intent"]=i; boot["snapshot"]=snap; cat["bootstrap"]=boot; c["catalog"]=cat
            return try JSONSerialization.data(withJSONObject:c)
        }
        let trueBytes = try changed { $0["sentryDesired"] = true }
        _ = try JSONDecoder().decode(LegacyForwarding.AudioForwardingState.self,from:trueBytes)
        check(try JSONDecoder().decode(StreamProtocol.AudioForwardingState.self,from:trueBytes).catalog?.bootstrap.snapshot.intent?.sentryDesired == true,
              "previous true intent remains compatible")
        for value: Any in [false, NSNull(), "true", 1] {
            let bytes = try changed { $0["localMutedDesired"] = value }
            check((try? JSONDecoder().decode(StreamProtocol.AudioForwardingState.self,from:bytes)) == nil,
                  "localMuted false/null/string/number remains rejected")
        }
        for key in intent.keys {
            let missing = try changed { $0.removeValue(forKey:key) }
            check((try? JSONDecoder().decode(StreamProtocol.AudioForwardingState.self,from:missing)) == nil,"each intent field remains required")
        }
        for value: Any in [NSNull(), "false", 0] {
            let bytes=try changed { $0["sentryDesired"] = value }
            check((try? JSONDecoder().decode(StreamProtocol.AudioForwardingState.self,from:bytes)) == nil,"sentry must remain a Bool")
        }
        for (key,value) in [("extra", true as Any),("intentRevision","0"),("intentRevision",1),("pairedDeviceId","not-an-id")] {
            let bytes=try changed { $0[key] = value }
            check((try? JSONDecoder().decode(StreamProtocol.AudioForwardingState.self,from:bytes)) == nil,"exact keys, positive canonical revision and identity remain required")
        }
        let current = try StreamProtocol.AudioForwardingSnapshot.Intent(pairedDeviceId: .init(hex:String(repeating:"a",count:64))!,
            intentId: UUID(), intentRevision:.init(1),intentGeneration:UUID(),inputDesired:true,outputDesired:true)
        check(!current.sentryDesired && current.localMutedDesired,"constructor default exactly matches Host241")
        check((try? StreamProtocol.AudioForwardingSnapshot.Intent(pairedDeviceId:current.pairedDeviceId,intentId:current.intentId,
            intentRevision:.init(1),intentGeneration:current.intentGeneration,inputDesired:true,outputDesired:true,
            sentryDesired:false,localMutedDesired:false)) == nil,"constructor still rejects unmuted local output")
        print("Sentry optional DTO contract: \(checks) checks passed; synthetic only")
    }
}
