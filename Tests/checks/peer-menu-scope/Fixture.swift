import Foundation
import Network
import ApplicationServices
import StreamProtocol
final class Stats { static let shared = Stats(); func bump(_ name: String) {} }
final class StreamServer {
    let sentryAdmission = SentryAdmission()
    func send(_ message: StreamMessage, to connection: NWConnection) {}
    func sendScopedMetadata(_ message: StreamMessage, to connection: NWConnection, admission: SourcePublicationAdmission) {}
}
final class ObservedMenuQueue: @unchecked Sendable {
    let raw = DispatchQueue(label: "isolated.menu.reader")
    var submissions = 0
    func async(execute work: @escaping @Sendable () -> Void) {
        submissions += 1
        raw.async(execute: work)
    }
}
final class MenuReader: @unchecked Sendable {
    let queue = ObservedMenuQueue()
    static let timeout: Float = 1
    static let readBudget = 1.5
    var reads = 0
    var presses = 0
    struct Read { let item: RawMenuItem; let index: Int; let element: AXUIElement }
    enum Failure: Error { case notTrusted, noMenuBar, gone, notAnswering, failed(String), notShown(found: String), moved, late }
    struct Menu { let reads: [Read]; let total: Int; let unread: Int; let ms: Double }
    struct Pressed {
        enum Outcome { case pressed, pressedNoAnswer, refused(MenuRefusal), moved }
        let outcome: Outcome; let foundTitle: String?
    }
    func topLevel(pid: pid_t) -> Result<(titles: [Read], ms: Double), Failure> {
        reads += 1
        return .success(([Read(item: RawMenuItem(title: "파일", enabled: true), index: 1,
                               element: AXUIElementCreateApplication(pid))], 0))
    }
    func items(pid: pid_t, of parent: AXUIElement?, path: MenuPath, shown: String, ancestors: [String]?, until: Double) -> Result<Menu, Failure> {
        reads += 1
        return .success(Menu(reads: [], total: 0, unread: 0, ms: 0))
    }
    func press(pid: pid_t, element: AXUIElement?, path: MenuPath, shownTitle: String?, ancestors: [String]?, expectedWindow: UInt32? = nil, requireFrontmost: Bool = false) -> Pressed {
        presses += 1
        return Pressed(outcome: .pressed, foundTitle: shownTitle)
    }
}

@MainActor final class MenuBoundaryFixture {
    let server = StreamServer()
    let peerInputQueue = PeerInputQueue()
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var peerMenus: [ObjectIdentifier: MenuMirror] = [:]
    func attach(_ mirror: MenuMirror, connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection; peerMenus[id] = mirror
        server.sentryAdmission.configure(latched: false, persistenceHealthy: true)
        server.sentryAdmission.register(id, externalRoute: false)
        server.sentryAdmission.admit(id)
        __EXECUTE_PRESS__
    }
    func releaseInput(of id: ObjectIdentifier) {}
    func revoke() {
        server.sentryAdmission.setLocalReturnRequestActive(true)
        __REVOKE_PRESS__
    }
    func resume() { server.sentryAdmission.setLocalReturnRequestActive(false) }
}
