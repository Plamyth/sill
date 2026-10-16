import Foundation

func startupTrustChecks() {
    func record(_ byte: UInt8, at time: Double) -> SavedMac {
        let fingerprint = Data(repeating: byte, count: 32)
        return SavedMac(macID: MacID.make(fingerprint: fingerprint), fingerprint: Base64URL.encode(fingerprint),
                        name: "Mac", recognitionKey: Base64URL.encode(Data(repeating: 9, count: 32)), remotePort: 7455,
                        addresses: [MacAddress(host: "100.101.102.103", kind: "vpn", via: "Tailscale")],
                        infoIssuedAt: 0, pairedAt: Date(timeIntervalSince1970: time), method: "code", homeTLS: true)
    }
    let old = record(1, at: 100), recent = record(2, at: 200)
    check("startup trust selects uniquely newest formal pairing", SavedMacs.automaticTarget([old, recent], preferredID: nil)?.macID == recent.macID)
    check("startup trust preserves explicit preference", SavedMacs.automaticTarget([old, recent], preferredID: old.macID)?.macID == old.macID)
    check("startup trust rejects missing preferred ID", SavedMacs.automaticTarget([old, recent], preferredID: "missing") == nil)
    var tied = recent; tied.pairedAt = old.pairedAt
    check("startup trust rejects tied migration", SavedMacs.automaticTarget([old, tied], preferredID: nil) == nil)
    var invalid: [SavedMac] = []
    var item = recent; item.revoked = true; invalid.append(item)
    item = recent; item.newKey = true; invalid.append(item)
    item = recent; item.homeTLS = false; invalid.append(item)
    item = recent; item.homeTLS = nil; invalid.append(item)
    item = recent; item.fingerprint = "invalid"; invalid.append(item)
    item = recent; item.recognitionKey = "invalid"; invalid.append(item)
    item = recent; item.macID = old.macID; invalid.append(item)
    for damaged in invalid {
        check("startup trust rejects damaged, unpaired, or revoked preferred record",
              SavedMacs.automaticTarget([damaged], preferredID: damaged.macID) == nil)
    }
}
