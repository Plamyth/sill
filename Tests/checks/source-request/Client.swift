import Foundation

final class AudioControl {
    var changes = 0
    func sourceWillChange() { changes += 1 }
}
final class Link {
    func send(_ data: Data, onlyOn peer: NSObject) -> Bool { true }
}
@MainActor final class Client {
    static let noAutoDesktop = false
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
    var sent: [(StreamMessageKind,Data)] = []
    func noteAction() {}
    func send(_ kind: StreamMessageKind, _ payload: Data) { sent.append((kind,payload)) }
    func deliverIdleCatalog(_ list: WindowList) {
        active = list.active
        // RESUME_SOURCE
    }
    // CLIENT_METHODS
}
