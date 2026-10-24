import Foundation
import CoreGraphics

// DISPLAY_INFO
struct DisplaySelection { let displayID: UInt32; let inventoryID: UUID }
typealias CGDirectDisplayID = UInt32

final class NWConnection {
    enum State { case ready, cancelled }
    var state: State = .ready
}
struct Hello { var device: String? = "iPad (iPad14,1)" }
struct Route { var encrypted = true; var fingerprint: Data? = Data([1]) }
final class Trust {
    var paired = true
    func isPaired(_ fingerprint: Data) -> Bool { paired && fingerprint == Data([1]) }
}
final class PeerFixture {
    var isClosed = false
    var viewports: [Viewport] = []
    func updateViewport(_ viewport: Viewport) { viewports.append(viewport) }
}
struct ViewportMessage {
    enum Kind { case viewport, other }
    let kind = Kind.viewport
    let payload: Data
    init(_ viewport: Viewport) { payload = try! JSONEncoder().encode(viewport) }
}
enum Wire {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

@MainActor
final class VirtualDisplay {
    var isAlive = true
    var requestedMode = false
    var modeChecks = 0
    var hasRequestedMode: Bool { modeChecks += 1; return requestedMode }
    var bounds: CGRect = .zero
    func selectRequestedMode() {}
}

@MainActor
enum AdapterWaitFixture {
    // ONLINE_WAIT_METHOD
}

@MainActor
final class CoordinatorFixture {
    var shuttingDown = false
    var appKitLoop = true
    var synthetic = false
    var independentStreamsEnabled = false
    var peerStreams: [ObjectIdentifier: PeerFixture] = [:]
    var extendedDesktopEligible: Set<ObjectIdentifier> = []
    var routes: [ObjectIdentifier: Route] = [:]
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var remote: Trust? = Trust()
    var extendedDesktopViewports: [ObjectIdentifier: ExtendedDesktop.Dimensions] = [:]
    let extendedDesktop: ExtendedDesktop
    init(_ desktop: ExtendedDesktop) { extendedDesktop = desktop }
    // COORDINATOR_METHOD
    // VIEWPORT_METHOD
    // PEER_VIEWPORT_METHOD

    func receiveHello(_ hello: Hello, from connection: NWConnection) {
        // HELLO_DESKTOP
    }

    func receive(_ viewport: Viewport, from connection: NWConnection) async {
        guard let lane = peerStreams[ObjectIdentifier(connection)] else { return }
        _ = await handlePeerMessage(ViewportMessage(viewport), from: connection, lane: lane)
    }

    func disconnect(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        // DISCONNECT_DESKTOP
        peerStreams[id] = nil
        connections[id] = nil
        routes[id] = nil
    }
}

@MainActor
final class CatalogFixture {
    struct Display { let displayID: UInt32 }
    var displays: [Display] = []
    var extendedDesktopID: UInt32?
    var displayInventory = DisplayInventory()
    var onDisplaysChanged: (() -> Void)?
    var clientCount = 0
    var refreshes = 0
    @discardableResult func refreshWindows() async -> Bool { refreshes += 1; return true }
    func displayInfo(id: UInt32, name: String, mainID: UInt32 = 1) -> DisplayInfo {
        struct Screen { let localizedName: String }
        let screen: Screen? = Screen(localizedName: name)
        let display = (width: 1350, height: 890)
        let index = 0
        // DISPLAY_INFO_CONSTRUCTION
    }
    // CATALOG_METHODS
}

@MainActor
final class FakeDisplay {
    let id: UInt32
    let dimensions: ExtendedDesktop.Dimensions
    let lost: @MainActor () -> Void
    var online: CheckedContinuation<Bool, Never>?
    var configuration: CheckedContinuation<Void, Never>?
    var blockConfiguration = false
    var configurationFails = false
    var valid = true
    var destroys = 0
    var recoveries = 0
    var configured = 0
    var events: [String] = []
    init(id: UInt32, dimensions: ExtendedDesktop.Dimensions, lost: @escaping @MainActor () -> Void) {
        self.id = id; self.dimensions = dimensions; self.lost = lost
    }
    var resource: ExtendedDesktop.Resource {
        .init(id: id, waitUntilOnline: { await withCheckedContinuation { self.online = $0 } },
            configure: {
                self.configured += 1
                if self.blockConfiguration { await withCheckedContinuation { self.configuration = $0 } }
                if self.configurationFails { throw TestFailure.configuration }
            }, isValid: { self.valid }, recoverWindows: { self.recoveries += 1; self.events.append("recover") },
            destroy: { self.destroys += 1; self.events.append("destroy") })
    }
}

enum TestFailure: Error { case creation, configuration }

@MainActor
final class Rig {
    var displays: [FakeDisplay] = []
    var published: [UInt32?] = []
    var failures: [String] = []
    var throwOnCreate = false
    lazy var desktop = ExtendedDesktop(makeDisplay: { dimensions, lost in
        if self.throwOnCreate { throw TestFailure.creation }
        let display = FakeDisplay(id: UInt32(self.displays.count + 100), dimensions: dimensions, lost: lost)
        self.displays.append(display)
        return display.resource
    }, publishID: { self.published.append($0) }, reportFailure: { self.failures.append($0) })
}
