import Foundation
import StreamProtocol

@main enum Checks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        count += 1
        precondition(value(), label)
    }
    @MainActor static func main() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vectors.json")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        for row in rows {
            let request = try JSONDecoder().decode(ProviderCallRequest.self,
                from: JSONSerialization.data(withJSONObject: row["request"]!))
            check(request.digest == row["requestDigest"] as? String, "independent binary request digest vector")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
            check(Set(encoded.keys) == ["requestId", "action", "expectedLeaseRevision", "pairedDeviceId", "desiredInput", "desiredOutput", "callSessionId"], "all seven fields include explicit null")
        }
        let base = rows[0]["request"] as! [String: Any]
        for changes in [["action":"stop","callSessionId":""], ["callSessionId":"other"], ["unexpected":true],
                        ["expectedLeaseRevision":"07"], ["desiredInput":1],
                        ["action":"stop","callSessionId":String(repeating:"😀",count:65)]] as [[String: Any]] {
            let raw = try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })
            check((try? JSONDecoder().decode(ProviderCallRequest.self, from: raw)) == nil, "malformed request never becomes authority")
        }
        var stop = base
        stop["action"] = "stop"
        let original = String(data: try JSONSerialization.data(withJSONObject: stop), encoding: .utf8)!
        let raw = original.replacingOccurrences(of: "\"callSessionId\":null", with: "\"callSessionId\":\"\\uD800\"")
        check(raw != original, "surrogate fixture actually changes input bytes")
        check((try? JSONDecoder().decode(ProviderCallRequest.self, from: Data(raw.utf8))) == nil, "unpaired UTF16 is rejected before digest encoding")
        print("PASS \(count) provider request/encoding assertions; no host/key/device/audio actions")
    }
}
