import Foundation

@main struct Checks {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name)
            count += 1
        }
        let pin = Data(repeating: 0x37, count: 32)
        let fingerprint = Base64URL.encode(pin)
        let macID = MacID.make(fingerprint: pin)
        let profile = OwnerMacBootstrap(macID: macID, fingerprint: fingerprint,
            addresses: ["100.64.1.2", "fd7a:115c:a1e0::2"], remotePort: 7455)!
        let data = try JSONEncoder().encode(profile)
        check("round trip", OwnerMacBootstrap.decodeResource(data) == profile)
        check("exact pin", profile.fingerprintData == pin)
        let valid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func resource(_ change: (inout [String: Any]) -> Void) throws -> OwnerMacBootstrap? {
            var object = valid
            change(&object)
            return OwnerMacBootstrap.decodeResource(try JSONSerialization.data(withJSONObject: object))
        }
        for field in valid.keys {
            check("required " + field, try resource { $0.removeValue(forKey: field) } == nil)
        }
        for field in ["recognitionKey", "privateKey", "token", "authenticated", "expiresAt", "unknown"] {
            check("public fields only " + field, try resource { $0[field] = "unexpected" } == nil)
        }
        for addresses in [[], ["127.0.0.1"], ["192.168.1.2"], ["100.63.1.2"], ["100.128.1.2"],
                          ["100.64.01.2"], ["100.64.1.2:7455"], [" 100.64.1.2"], ["mac.example.invalid"],
                          ["fd7a:115c:a1e1::2"], ["[fd7a:115c:a1e0::2]"], ["fd7a:115c:a1e0::2%en0"],
                          ["::ffff:100.64.1.2"], ["100.64.1.2", "100.64.1.2"],
                          (1...9).map { "100.64.1.\($0)" }] {
            check("reject noncanonical or unbounded addresses", try resource { $0["addresses"] = addresses } == nil)
        }
        for port in [0, -1, 65536, Int.max] {
            check("reject port", try resource { $0["remotePort"] = port } == nil)
        }
        for bad in ["", fingerprint + "=", Base64URL.encode(Data(repeating: 0, count: 31))] {
            check("reject pin", try resource { $0["fingerprint"] = bad } == nil)
        }
        check("identity must match pin", try resource { $0["macID"] = String(repeating: "0", count: 16) } == nil)
        check("reject another schema", try resource { $0["schema"] = "ccr.owner-mac-bootstrap/v2" } == nil)
        check("reject oversized resource", OwnerMacBootstrap.decodeResource(Data(repeating: 32, count: 4097)) == nil)
        check("reject malformed JSON", OwnerMacBootstrap.decodeResource(Data("{".utf8)) == nil)
        check("reject array", OwnerMacBootstrap.decodeResource(Data("[]".utf8)) == nil)
        print("PASS \(count) public owner bootstrap profile checks; no socket, identity creation or device effects")
    }
}
