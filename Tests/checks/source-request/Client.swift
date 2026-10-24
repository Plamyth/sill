import Foundation

final class AudioControl {
    var changes = 0
    func sourceWillChange() { changes += 1 }
}
final class NWConnection: NSObject, @unchecked Sendable {
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var packets: [Data] = []
    func forceCancel() {}
    func send(content: Data?, completion: SendCompletion) {
        if let content { packets.append(content) }
        if case .contentProcessed(let done) = completion { done(nil) }
    }
}
final class TestDefaults {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) { values[key] = data }
}
struct SavedMac {
    var macID: String
    var fingerprintData: Data?
}
enum SavedMacs {
    static func automaticTarget(_ macs: [SavedMac], preferredID: String) -> SavedMac? {
        macs.first { $0.macID == preferredID }
    }
}
@MainActor final class Client {
    static let noAutoDesktop = false
    // EXPECTED_SOURCE
    // EXPECTED_SOURCE_STATE
    // AUTOMATIC_TICKET
    // DISPLAY_TYPES
    // SOURCE_ADMISSION_STATE
    var defaults = TestDefaults()
    enum Route { case network, remote; var isRemote: Bool { self == .remote } }
    enum HomeTrust { case plain, saved(pin: Data) }
    struct Session {
        var macID: String? = "trusted-mac"
        var route = Route.network
        var home: HomeTrust? = .saved(pin: Data([1]))
    }
    var session: Session? = Session()
    var savedMacs = [SavedMac(macID: "trusted-mac", fingerprintData: Data([1]))]
    var automaticDisplayCatalogObserved = false
    var initialDisplayOpportunity: InitialDisplayOpportunity?
    var automaticDisplaySelection: Int?
    var pendingDisplaySelection: PendingDisplaySelection?
    var lastStartupCatalogDiagnostic: [String: String]?
    var startupVideoRecorded = false
    func recordStartupDiagnostic(_ fields: [String: String]) {}
    var explicitSourceIntent: UInt64 = 0
    var automaticSourceIntent: UInt64? = 0
    var sourceCatalogEpoch: UUID?
    var selectionRevision: String? = "revision-0"
    var sessionHost: String? = "host"
    var resumeOpportunity: AutomaticConnectionOpportunity?
    var scheduledAutomaticTicket: AutomaticSourceTicket?
    var automaticSubmission: SessionLink.Submission?
    var resumeSource: StreamSource?
    var active = StreamSource.window(1001)
    var remoteAudioControl = AudioControl()
    var link = SessionLink()
    var choicesSent = 0
    var actions = 0
    var displaySelectionReady = true
    var connection: NWConnection? { get { link.connection } set { link.connection = newValue } }
    init() { link.connection = NWConnection() }
    var displayInventoryID: UUID? = UUID()
    var desktopSelectionRequired = false
    var displays = [DisplayInfo(id:13,name:"CCR",width:2700,height:1952,isMain:false)]
    var lastAutoDesktop = Date.distantPast
    var lastRttMaxMs: Int?
    var connected = true
    var windows: [WindowInfo] = []
    var allSent: [(StreamMessageKind, Data)] {
        (link.connection?.packets ?? []).compactMap { data in
            guard let header = StreamMessage.parseHeader(Data(data.prefix(StreamMessage.headerLength))) else { return nil }
            return (header.kind, Data(data.dropFirst(StreamMessage.headerLength)))
        }
    }
    func noteAction() { actions += 1 }
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        link.send(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized())
    }
    func deliverIdleCatalog(_ list: WindowList, from incoming: NWConnection? = nil) {
        guard incoming == nil || incoming === connection else { return }
        let previous = active
        let peer = connection!
        prepareAutomaticTicketCatalog(list)
        // RESUME_SOURCE
        requestInitialDisplay(list, peer: peer)
        // IDLE_FALLBACK
    }
    func prepareAutomaticTicketCatalog(_ list: WindowList) {
        let peer = connection!
        active = list.active
        windows = list.windows
        sessionHost = list.launchID
        observeSourceSelectionAdmission(list, peer: peer)
        observeDisplaySelection(list, peer: peer)
        observeSourceIntent(list)
        sourceCatalogEpoch = list.videoEpoch?.id
        selectionRevision = list.selectionRevision
        automaticDisplaySelection = list.automaticDisplaySelection
        displayInventoryID = list.displayInventoryID
        displaySelectionReady = list.displaySelection == 1 && list.displayInventoryID != nil
        desktopSelectionRequired = list.desktopSelectionRequired == true
        displays = list.displays ?? []
    }
    // CLIENT_METHODS
}
