import Foundation

func retirementChecks() {
    let address = MacAddress(host: "100.101.102.103", kind: "vpn", via: "Tailscale")
    func record(_ byte: UInt8, name: String, method: String, paired: Double, last: Double?) -> SavedMac {
        let fp = Data(repeating: byte, count: 32)
        return SavedMac(macID: MacID.make(fingerprint: fp), fingerprint: Base64URL.encode(fp), name: name,
                        recognitionKey: Base64URL.encode(Data(repeating: 8, count: 32)), remotePort: 7455,
                        addresses: [address], infoIssuedAt: 100, pairedAt: Date(timeIntervalSince1970: paired),
                        method: method, lastConnectedAt: last.map { Date(timeIntervalSince1970: $0) }, homeTLS: true)
    }
    let old = record(11, name: "강태완의 MacBook Pro", method: "qr", paired: 1792107647, last: 1792126432)
    let ccr = record(22, name: old.name + " · CCR Sill", method: "cable", paired: 1792138802, last: nil)
    var other = record(33, name: "Unrelated", method: "code", paired: 1, last: 2)
    other.addresses = [MacAddress(host: "100.111.112.113", kind: "vpn", via: "Tailscale")]
    func retire(_ records: [SavedMac], preferred: String? = nil, pin: Data? = nil,
                live: [MacAddress]? = nil) -> [SavedMac]? {
        R.retiringCCROriginal(preferredID: preferred ?? ccr.macID, authenticatedPin: pin ?? ccr.fingerprintData!,
                             verifiedAddresses: live ?? [address], in: records)
    }
    let records = [old, ccr, other]
    let next = retire(records)
    check("CCR retirement removes only original QR record with exact name, chronology, and unique live Tailscale proof", next == [ccr, other])
    check("CCR retirement preserves current key and every saved field", next?.first == ccr)
    check("CCR retirement is idempotent", next.flatMap { retire($0) } == nil)
    check("CCR name difference still cannot relax ordinary TLS successor policy",
          R.successors(of: old, at: R.Candidate(host: address.host, port: 7455, kind: "vpn", via: "Tailscale"),
                       in: records, allowLoopback: false).isEmpty)
    check("CCR retirement needs preferred current identity", retire(records, preferred: old.macID) == nil)
    check("CCR retirement needs authenticated current pin", retire(records, pin: old.fingerprintData!) == nil)
    check("CCR retirement needs live signed address proof", retire(records, live: []) == nil)
    check("CCR retirement needs live address shared with saved records", retire(records, live: other.addresses) == nil)
    var changed = old; changed.name += " different"
    check("CCR retirement never uses fuzzy name matching", retire([changed, ccr]) == nil)
    changed = old; changed.lastConnectedAt = nil
    check("CCR retirement needs original last connection evidence", retire([changed, ccr]) == nil)
    changed = old; changed.lastConnectedAt = ccr.pairedAt
    check("CCR retirement rejects original used since current pairing", retire([changed, ccr]) == nil)
    changed = old; changed.lastConnectedAt = Date(timeIntervalSince1970: 1)
    check("CCR retirement rejects inconsistent chronology", retire([changed, ccr]) == nil)
    changed = old; changed.method = "code"
    check("CCR retirement is limited to original QR pairing", retire([changed, ccr]) == nil)
    changed = ccr; changed.method = "qr"
    check("CCR retirement is limited to CCR cable pairing", retire([old, changed]) == nil)
    changed = ccr; changed.revoked = true
    check("CCR retirement rejects revoked current pairing", retire([old, changed]) == nil)
    changed = ccr; changed.newKey = true
    check("CCR retirement rejects changed current key", retire([old, changed]) == nil)
    changed = old; changed.addresses = other.addresses
    check("CCR retirement rejects name and chronology without shared address", retire([changed, ccr]) == nil)
    changed = other; changed.addresses = [address]
    check("CCR retirement rejects Tailscale address shared by a third record", retire([old, ccr, changed]) == nil)
    for host in ["192.168.1.2", "mac.local", "203.0.113.2", "127.0.0.1"] {
        let nonUnique = MacAddress(host: host, kind: "vpn", via: "Tailscale")
        var a = old, b = ccr; a.addresses = [nonUnique]; b.addresses = [nonUnique]
        check("CCR retirement rejects LAN, loopback, and generic internet addresses even when labelled VPN",
              retire([a, b], live: [nonUnique]) == nil)
    }
    changed = old; changed.recognitionKey = "invalid"
    check("CCR retirement rejects damaged original identity", retire([changed, ccr]) == nil)
    check("CCR retirement rejects duplicate IDs", retire([old, ccr, old]) == nil)
    var sameName = other; sameName.name = old.name
    check("CCR retirement preserves unrelated Mac with same original name", retire([old, ccr, sameName]) == [ccr, sameName])
    retirementGlueChecks(old: old, current: ccr, other: other)
}
