import Foundation
import CryptoKit
import StreamProtocol

extension Checks {
    static func decode<T: Decodable>(_ type: T.Type, _ raw: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }

    static func nativeHash(_ raw: [String: Any]) throws -> String {
        let parts = ["schema", "providerKind", "providerInstanceId", "threadId", "voiceSessionId"].map { raw[$0] as! String }
        let bytes = try JSONSerialization.data(withJSONObject: parts, options: [.withoutEscapingSlashes])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func nativeTargets(request: ProviderCallRequest) throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("native-target-vectors.json")
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let rows = vectors["vectors"] as! [[String: Any]]
        var hashes: [String] = []
        for row in rows {
            let raw = row["target"] as! [String: Any]
            let typed = try decode(ProviderCallTarget.self, raw)
            guard case .nativeTarget(let native) = typed else { preconditionFailure("native typed branch") }
            for key in ["providerInstanceId", "threadId", "voiceSessionId"] {
                let preserved = ["providerInstanceId": native.providerInstanceId,
                    "threadId": native.threadId, "voiceSessionId": native.voiceSessionId]
                check(preserved[key] == raw[key] as? String, "UUID source case and bytes preserved")
            }
            let canonical = try JSONSerialization.data(withJSONObject: [native.schema, native.providerKind,
                native.providerInstanceId, native.threadId, native.voiceSessionId], options: [.withoutEscapingSlashes])
            check(String(data: canonical, encoding: .utf8) == row["canonicalUTF8"] as? String, "exact JSON.stringify UTF8 bytes")
            let hash = try typed.hash()
            check(hash == row["sha256"] as? String && hash == native.targetHash, "fixed native golden SHA256")
            hashes.append(hash)
            var challenge: [String: Any] = ["schemaVersion": 1,
                "challenge": Base64URL.encode(Data(repeating: 7, count: 32)),
                "coreGeneration": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "requestId": request.requestId.uuidString.lowercased(), "target": raw,
                "targetHash": hash, "guestNowMs": 0, "remainingMilliseconds": 1500]
            try decode(ProviderCallChallenge.self, challenge).validate(request)
            check(true, "native challenge validates before signing")
            for wrong in [String(repeating: "0", count: 64), hash.uppercased(), ""] {
                challenge["targetHash"] = wrong
                let value = try decode(ProviderCallChallenge.self, challenge)
                var rejected = false
                do { try value.validate(request) } catch { rejected = true }
                check(rejected, "external targetHash mismatch rejected before signing")
                var changed = raw; changed["targetHash"] = wrong
                check((try? decode(ProviderCallTarget.self, changed)) == nil, "internal targetHash must equal computed lowercase SHA256")
                challenge["target"] = changed
                check((try? decode(ProviderCallChallenge.self, challenge)) == nil, "equal but forged internal and external hashes rejected")
                challenge["target"] = raw
            }
            for key in raw.keys {
                var changed = raw; changed.removeValue(forKey: key)
                check((try? decode(ProviderCallTarget.self, changed)) == nil, "every native key required: \(key)")
            }
            for changes in [["schema": "ccr-provider-target-v1"], ["providerKind": "chatgpt-dots-webguest"],
                ["providerKind": "arbitrary"], ["extra": true], ["profileId": "codex-control-room-chatgpt-dots"],
                ["leafId": "leaf"], ["guestId": 1], ["url": "https://chatgpt.com/dots/test"], ["timeOrigin": 1],
                ["realtimeSessionId": "session"], ["version": "v1"]] as [[String: Any]] {
                var changed = raw.merging(changes) { _, new in new }
                changed["targetHash"] = try nativeHash(changed)
                check((try? decode(ProviderCallTarget.self, changed)) == nil,
                    "wrong schema/provider, mixed target, extra or started-event field rejected")
            }
            let rejects = vectors["rejectIdentifiers"] as! [String]
            for key in ["providerInstanceId", "threadId", "voiceSessionId"] {
                for invalid in rejects + ["675e086f96724f3fa8d2ff690ac6cae0", " 675e086f-9672-4f3f-a8d2-ff690ac6cae0",
                    "675e086f-9672-4f3f-a8d2-ff690ac6caeg", "675e086f-9672-4f3f-a8d2-ff690ac6cae0\n"] {
                    var changed = raw; changed[key] = invalid
                    changed["targetHash"] = try nativeHash(changed)
                    check((try? decode(ProviderCallTarget.self, changed)) == nil, "bad UUID rejected even with matching hash")
                }
                for invalid in [NSNull(), NSNumber(value: 1)] as [Any] {
                    var changed = raw; changed[key] = invalid
                    check((try? decode(ProviderCallTarget.self, changed)) == nil, "UUID must be a non-null string")
                }
            }
        }
        check(hashes.count == 2 && hashes[0] != hashes[1], "UUID case variants have distinct hashes")

        let legacy: [String: Any] = ["profileId": "codex-control-room-chatgpt-dots", "leafId": "leaf:one", "guestId": 7,
            "url": "https://chatgpt.com/dots/fixture", "timeOrigin": 1_700_000_000_000.125]
        let old = try decode(ProviderCallTarget.self, legacy)
        guard case .webGuest = old else { preconditionFailure("legacy typed branch") }
        let oldHash = try old.hash()
        check(oldHash == "46193289c1f905bda74aaa26941a91100a1ae6dc7a971d1334bc54e2a80ec8be", "legacy hash bytes unchanged")
        for key in legacy.keys {
            var changed = legacy; changed.removeValue(forKey: key)
            check((try? decode(ProviderCallTarget.self, changed)) == nil, "every legacy key required")
        }
        for changes in [["profileId": "other"], ["leafId": "../leaf"], ["leafId": ""], ["guestId": 0],
            ["guestId": 9_007_199_254_740_992 as UInt64], ["timeOrigin": 0], ["extra": true],
            ["targetHash": oldHash], ["providerKind": "codex-app-server"], ["schema": "ccr-codex-realtime-target-v1"]] as [[String: Any]] {
            check((try? decode(ProviderCallTarget.self, legacy.merging(changes) { _, new in new })) == nil,
                "legacy identifier/clock/range and exact five-key contract preserved")
        }
        for url in ["http://chatgpt.com/dots/test", "https://evil.test/dots/test", "https://chatgpt.com/dots/test?x=1",
            "https://chatgpt.com/dots/test#fragment", "https://chatgpt.com:443/dots/test",
            "https://user:password@chatgpt.com/dots/test", "https://chatgpt.com/other/test",
            "https://chatgpt.com/dots/" + String(repeating: "x", count: 2048)] {
            var changed = legacy; changed["url"] = url
            check((try? decode(ProviderCallTarget.self, changed)) == nil, "legacy URL validation preserved")
        }

        let defaultResult = try ProviderCallResult(requestId: request.requestId, status: .unsupported, reason: "fixture_unsupported")
        check(defaultResult.provider == "chatgpt-dots-webguest", "default legacy/unsupported provider preserved")
        for provider in ["chatgpt-dots-webguest", "codex-app-server"] {
            let value = try ProviderCallResult(requestId: request.requestId, status: .started, reason: "fixture_readback", provider: provider)
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            check(Set(wire.keys) == ["requestId", "status", "reason", "callSessionId", "provider", "mediaProtection"], "result exact six-field contract")
            let decoded = try decode(ProviderCallResult.self, wire)
            check(decoded.provider == provider && decoded.mediaProtection == "not_attested", "explicit provider constructor/decode roundtrip")
            for key in wire.keys {
                var changed = wire; changed.removeValue(forKey: key)
                check((try? decode(ProviderCallResult.self, changed)) == nil, "every result key required")
            }
            for changes in [["provider": "other"], ["provider": "Codex-app-server"], ["provider": ""],
                ["mediaProtection": "attested"], ["mediaProtection": "local_hal_protected"], ["mediaProtection": NSNull()],
                ["extra": true]] as [[String: Any]] {
                check((try? decode(ProviderCallResult.self, wire.merging(changes) { _, new in new })) == nil,
                    "result provider allowlist, exact keys and no false media attestation")
            }
        }
        for provider in ["other", "Codex-app-server", ""] {
            check((try? ProviderCallResult(requestId: request.requestId, status: .failed, reason: "fixture_failed", provider: provider)) == nil,
                "arbitrary constructor provider rejected")
        }
    }
}
