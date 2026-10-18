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
@MainActor final class Client {
    static let noAutoDesktop = false
    // EXPECTED_SOURCE
    var expectedSourceIntent: (choice: ExpectedSourceIntent, revision: String?, epoch: UUID?)?
    // AUTOMATIC_TICKET
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
    func noteAction() {}
    func send(_ kind: StreamMessageKind, _ payload: Data) {
        link.send(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: payload).serialized())
    }
    func deliverIdleCatalog(_ list: WindowList) {
        let previous = active
        let peer = connection!
        active = list.active
        windows = list.windows
        sessionHost = list.launchID
        observeSourceIntent(list)
        sourceCatalogEpoch = list.videoEpoch?.id
        selectionRevision = list.selectionRevision
        // RESUME_SOURCE
        // IDLE_FALLBACK
    }
    // CLIENT_METHODS
}
