import Foundation

struct FakeTime {
    let value: Double
    static func now() -> Self { Self(value: Clock.now) }
    static func + (lhs: Self, rhs: Double) -> Self { Self(value: lhs.value + rhs) }
}
final class FakeWorkItem {
    let body: () -> Void
    var cancelled = false
    init(block: @escaping () -> Void) { body = block }
    func cancel() { cancelled = true }
}
enum Clock {
    static var now = 0.0
    static var jobs: [(Double, Int, FakeWorkItem)] = []
    static var serial = 0
    static func schedule(_ at: Double, _ item: FakeWorkItem) {
        serial += 1
        jobs.append((at, serial, item))
    }
    static func advance(_ duration: Double = 0) {
        let end = now + duration
        while let next = jobs.enumerated().filter({ $0.element.0 <= end }).min(by: {
            ($0.element.0, $0.element.1) < ($1.element.0, $1.element.1)
        }) {
            let job = jobs.remove(at: next.offset)
            now = job.0
            if !job.2.cancelled { job.2.body() }
        }
        now = end
    }
    static func reset() { now = 0; jobs = []; serial = 0 }
    static var pending: Int { jobs.filter { !$0.2.cancelled }.count }
}
final class FakeQueue {
    func async(execute: @escaping () -> Void) { Clock.schedule(Clock.now, FakeWorkItem(block: execute)) }
    func asyncAfter(deadline: FakeTime, execute: FakeWorkItem) { Clock.schedule(deadline.value, execute) }
    func asyncAfter(deadline: FakeTime, execute: @escaping () -> Void) {
        Clock.schedule(deadline.value, FakeWorkItem(block: execute))
    }
}
enum NWError: Error { case posix(Code); enum Code { case EADDRINUSE, ENETDOWN, EINVAL } }
enum NWEndpoint {
    struct Port: Equatable { let rawValue: UInt16 }
    case service(name: String, type: String, domain: String, interface: Int?)
}
final class NWConnection { var cancelled = false; func cancel() { cancelled = true } }
struct NWPath { enum Status { case satisfied, unsatisfied }; let status: Status }
final class NWPathMonitor {
    var pathUpdateHandler: ((NWPath) -> Void)?
    var cancelled = false
    func start(queue: FakeQueue) {}
    func cancel() { cancelled = true }
    func report(_ status: NWPath.Status) { pathUpdateHandler?(NWPath(status: status)) }
}
final class NWListener {
    enum State { case ready, failed(NWError), waiting(NWError), cancelled }
    enum Change { case add(NWEndpoint), remove(NWEndpoint) }
    struct Service {}
    struct Parameters { var includePeerToPeer: Bool }
    var parameters: Parameters
    var port: NWEndpoint.Port?
    var service: Service?
    var stateUpdateHandler: ((State) -> Void)?
    var serviceRegistrationUpdateHandler: ((Change) -> Void)?
    var newConnectionHandler: ((NWConnection) -> Void)?
    var cancellationAcknowledged = true
    var cancels = 0
    var starts = 0
    init(peerToPeer: Bool = false, port: NWEndpoint.Port? = NWEndpoint.Port(rawValue: 4000)) {
        parameters = Parameters(includePeerToPeer: peerToPeer)
        self.port = port
    }
    func start(queue: FakeQueue) { starts += 1 }
    func cancel() {
        cancels += 1
        if cancellationAcknowledged, let callback = stateUpdateHandler {
            Clock.schedule(Clock.now, FakeWorkItem { callback(.cancelled) })
        }
    }
    func report(_ state: State) { stateUpdateHandler?(state) }
}
final class Harness {
    enum HomeMode { case plain, closed(String) }
    let queue = FakeQueue()
    var listener = NWListener()
    var homeRecovery = HomeListenerRecovery()
    var homeRetryItem: FakeWorkItem?
    var homePathMonitor: NWPathMonitor?
    var homePathSatisfied: Bool?
    var homeBoundPort: NWEndpoint.Port?
    var recoverySwap = false
    var started = false
    var peerToPeer = false
    var wantedPeerToPeer = false
    enum Swap: Equatable { case idle, cancelling(Int), settling(Int) }
    var swap = Swap.idle
    var swapCount = 0
    var replacementPort: NWEndpoint.Port?
    var portLock = NSLock()
    var readyPort: UInt16?
    static let advertiseDelay = 1.5
    static let cancelTimeout = 1.0
    var testHost = false
    static var testSwapFail = ""
    var serviceNameAndType: (name: String, type: String)? = ("isolated", "unused")
    var txtRecord: (() -> Int?)?
    var serviceIsTest = false
    var homeMode = HomeMode.plain
    var onListenerFailed: ((NWError) -> Void)? = { _ in }
    var onListenerState: ((NWListener.State) -> Void)?
    var onServiceRegistered: ((String?) -> Void)?
    var builds: [(Bool, UInt16?)] = []
    var made: [NWListener] = []
    var failBuilds = 0
    var disconnected = 0
    var accepted = 0
    init() { wire(listener) }
    func makeService() -> NWListener.Service? { NWListener.Service() }
    func makeListener(peerToPeer: Bool, port: NWEndpoint.Port?) throws -> NWListener {
        builds.append((peerToPeer, port?.rawValue))
        if failBuilds > 0 { failBuilds -= 1; throw NWError.posix(.EADDRINUSE) }
        let made = NWListener(peerToPeer: peerToPeer, port: port ?? NWEndpoint.Port(rawValue: 4999))
        self.made.append(made)
        return made
    }
    func accept(_ connection: NWConnection, peerToPeer: Bool) { accepted += 1 }
    func disconnectPeerToPeerClients() { disconnected += 1 }

    // LIFECYCLE_METHODS
}
