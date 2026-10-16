import Foundation

enum RetirementDefaults {
    static var standard = RetirementPreferences()
}
struct RetirementPreferences {
    var preferred: String?
    func string(forKey key: String) -> String? { preferred }
}
final class RetirementClient {
    static let preferredTrustedMacKey = "Sill.preferredTrustedMacID"
    enum Pairing { case idle, working }
    struct Session {
        enum Route { case remote, network; var isRemote: Bool { self == .remote } }
        var route = Route.network
        var macID: String?
        var home: DiscoveryPolicy.HomeTrust?
    }
    var connected = true
    var pairing = Pairing.idle
    var pairingDial: Int?
    var homeAsk: Int?
    var overlayAskDialer: Int?
    var overlayAskShown: Int?
    var pendingLink: Int?
    var session: Session?
    var savedMacs: [SavedMac] = []
    var macInfoVerified: (MacInfo, Data)?
    var writes = 0
    func savedMac(_ id: String) -> SavedMac? { savedMacs.first { $0.macID == id } }
    func persistSavedMacs() { writes += 1 }
    // EXTRACTED_RETIREMENT
}

func retirementGlueChecks(old: SavedMac, current: SavedMac, other: SavedMac) {
    func client() -> RetirementClient {
        let c = RetirementClient()
        RetirementDefaults.standard.preferred = current.macID
        c.savedMacs = [old, current, other]
        c.session = RetirementClient.Session(macID: current.macID, home: .saved(pin: current.fingerprintData!))
        c.macInfoVerified = (MacInfo(macID: current.macID, name: current.name, issuedAt: current.infoIssuedAt,
                                     remoteAccess: true, remotePort: current.remotePort, internet: false,
                                     addresses: current.addresses), current.fingerprintData!)
        return c
    }
    do {
        let c = client(); let session = c.session
        c.retireOriginalCCREntryIfProven(); c.retireOriginalCCREntryIfProven()
        check("retirement glue persists removal exactly once after pinned home admission", c.savedMacs == [current, other] && c.writes == 1)
        check("retirement glue preserves preferred ID and active session pin",
              RetirementDefaults.standard.preferred == current.macID && c.session?.home == session?.home)
    }
    do {
        let c = client(); c.session?.route = .remote; c.session?.home = nil
        c.retireOriginalCCREntryIfProven()
        check("retirement glue accepts admitted pinned remote session with signed proof", c.writes == 1)
    }
    for mode in 0..<13 {
        let c = client()
        switch mode {
        case 0: c.connected = false
        case 1: c.session?.home = .plain
        case 2: c.macInfoVerified = nil
        case 3: c.macInfoVerified?.1 = old.fingerprintData!
        case 4: RetirementDefaults.standard.preferred = old.macID
        case 5: c.pairing = .working
        case 6: c.pairingDial = 1
        case 7: c.homeAsk = 1
        case 8: c.overlayAskDialer = 1
        case 9: c.overlayAskShown = 1
        case 10: c.pendingLink = 1
        case 11: c.macInfoVerified?.0.issuedAt -= 1
        default: c.macInfoVerified?.0.macID = old.macID
        }
        c.retireOriginalCCREntryIfProven()
        check("retirement glue rejects unadmitted, unpinned, unsigned, stale, nonpreferred, or pairing-busy state \(mode)",
              c.savedMacs == [old, current, other] && c.writes == 0)
    }
}
