import Foundation

extension NWConnection {
    var endpoint: String { "fixture" }
    var currentPath: String { "fixture" }
    func cancel() { forceCancel() }
}
extension SavedMacs {
    static func seenOverTLS(_ ids: [String], in macs: [SavedMac]) -> [SavedMac]? { macs }
}
extension AudioControl { func setConnection(_ peer: ObjectIdentifier) {} }
struct MoveBinding {
    mutating func bind(_ peer: ObjectIdentifier) {}
    mutating func reset() {}
    mutating func setPresentation(epoch: UUID?, peer: ObjectIdentifier?, modern: Bool) {}
}
struct MovePointer { func handedOver() -> Bool { false } }
struct MoveSettings { mutating func reset() {} }
struct MoveQueue { func async(_ action: @escaping () -> Void) {} }
struct PathSignals {}
enum DiscoveryPolicy { struct HomeMoveInfo {} }

// CLIENT_FIELDS
    enum MoveKind { case fromDirect, fromRemote, toCable, toWifi }
    enum InputBinding { case awaitingCatalog }
    static let fenceTimeout: TimeInterval = 1000
    var moving: NWConnection?
    var connectedDirectly = false
    var sessionDead = false
    var sentryReturn = MoveBinding()
    var visionInputBinding = InputBinding.awaitingCatalog
    var visionModernPeer: ObjectIdentifier?
    var displayView = MoveBinding()
    var macRouteTransport = MoveBinding()
    var macAudioRoutes = MoveBinding()
    var pointerFeed = MovePointer()
    var failedUps: String?
    var homeMoveName: String?
    var hostName = "fixture"
    var homeMoveTrust: HomeTrust?
    var homeMoveRow: String?
    var remoteRoute: String?
    var homeInfo = DiscoveryPolicy.HomeMoveInfo()
    var failedHomeMoves: String?
    var pathSignals = PathSignals()
    var lastPongAt: TimeInterval = 0
    var status = ""
    var settings = MoveSettings()
    var settingsProblem: String?
    var settingsExpiry: DispatchWorkItem?
    var connectedAt: Date?
    var homeMoveViewport: Viewport?
    var queue = MoveQueue()
    func invalidateIPadSentryReturn() {}
    func microphoneSetConnection(_ peer: NWConnection) {}
    func closeSoon(_ peers: [NWConnection]) {}
    func persistSavedMacs() {}
    func setRoute(from path: String, fresh: Bool) {}
    func startMeasuring(_ peer: NWConnection, remote: Bool) {}
    func deliver(_ header: StreamHeader, _ payload: Data, from peer: NWConnection) {}
    func startReading(_ peer: NWConnection) {}
    func menusMoved() {}
    func resumeOwnerEnrollment() {}
    func fenceEnded(_ peer: NWConnection, _ released: SessionLink.Released, why: String) {}
    func updateDiscovery() {}
    func followBestPath() {}
// END_CLIENT_FIELDS
