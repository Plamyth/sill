import Foundation

final class AudioControl {
    var changes = 0
    func sourceWillChange() { changes += 1 }
}
final class Link {
    var packets: [Data] = []
    func send(_ data: Data, onlyOn peer: NSObject) -> Bool { packets.append(data); return true }
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
    var resumeTicket: AutomaticSourceTicket?
    var scheduledAutomaticTicket: AutomaticSourceTicket?
    var resumeSource: StreamSource?
    var active = StreamSource.window(1001)
    var remoteAudioControl = AudioControl()
    var link = Link()
    var choicesSent = 0
    var displaySelectionReady = true
    var connection: NSObject? = NSObject()
    var displayInventoryID: UUID? = UUID()
    var desktopSelectionRequired = false
    var displays = [DisplayInfo(id:13,name:"CCR",width:2700,height:1952,isMain:false)]
    var lastAutoDesktop = Date.distantPast
    var lastRttMaxMs: Int?
    var connected = true
    var windows: [WindowInfo] = []
    var allSent: [(StreamMessageKind, Data)] {
        sent + link.packets.compactMap { data in
            guard let header = StreamMessage.parseHeader(Data(data.prefix(StreamMessage.headerLength))) else { return nil }
            return (header.kind, Data(data.dropFirst(StreamMessage.headerLength)))
        }
    }
    var sent: [(StreamMessageKind,Data)] = []
    func noteAction() {}
    func send(_ kind: StreamMessageKind, _ payload: Data) { sent.append((kind,payload)) }
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
