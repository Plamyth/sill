import Foundation

final class FixtureQueue {
    var work: [() -> Void] = []
    func async(execute: @escaping () -> Void) { work.append(execute) }
    func drain() { let pending = work; work.removeAll(); pending.forEach { $0() } }
}
final class NWConnection {
    enum Completion { case contentProcessed((Error?) -> Void) }
    var sent: [Data] = []
    func send(content: Data?, completion: Completion) {
        if let content { sent.append(content) }
    }
}
struct FixtureEpoch { let id: UUID }
struct FixtureBinding { let epoch: FixtureEpoch? }
struct VisionAudioScope: Equatable { let id = UUID() }
final class InertHardware {
    var isIdle = true
    var holdCleanup = false
    var revoked: [UUID] = []
    func revoke(owner: UUID) { revoked.append(owner) }
}
enum VisionAudioSharedHardware { static let shared = InertHardware() }
final class InertPlayback {
    var starts = 0, stops = 0
    func enable(expectedScope: VisionAudioScope?) -> Bool {
        starts += 1
        VisionAudioSharedHardware.shared.isIdle = false
        return true
    }
    func stop() {
        stops += 1
        if !VisionAudioSharedHardware.shared.holdCleanup { VisionAudioSharedHardware.shared.isIdle = true }
    }
}
struct InertForwarding {
    func permits(_ direction: VisionRemoteAudioIntent.Direction) -> Bool { true }
}
final class StreamClient {
    var visionForwarding: InertForwarding? = InertForwarding()
    var visionPlaybackDesired: Bool { store.model.intent.desired(.playback, hostKey: context.hostKey) }
    var visionMicrophoneDesired: Bool { store.model.intent.desired(.microphone, hostKey: context.hostKey) }
    var nativeSelections = 0
    func suspendVisionForwarding() { store.discardPendingSelections(self) }
    func reconcileVisionForwarding(manual: Bool = false) { if manual { nativeSelections += 1 } }
    let visionAudioOwnerID = UUID()
    let visionAudio = InertPlayback()
    var context: VisionRemoteAudioIntent.Context
    let queue = FixtureQueue()
    var connection: NWConnection? = NWConnection()
    var authenticatedVisionMacAudioPeer: ObjectIdentifier? { connection.map(ObjectIdentifier.init) }
    var visionWireBinding: (binding: FixtureBinding, unused: Bool)? {
        context.scope.map { (FixtureBinding(epoch: FixtureEpoch(id: $0.video)), false) }
    }
    var visionAudioIntentCatalog: WindowList? = WindowList(macName: "fixture", windows: [], active: .desktop, catalogRefresh: 1)
    func receiveCatalog(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        visionAudioIntentCatalog = list
        receiveVisionAudioCatalogAcknowledgement(list, from: peer)
        store.refresh()
    }
    func respondToQuery() {
        queue.drain()
        guard let peer = connection, let bytes = peer.sent.last,
              let header = StreamMessage.parseHeader(bytes), header.kind == .fetchCatalog,
              let query = Wire.decode(FetchCatalog.self, from: Data(bytes.dropFirst(StreamMessage.headerLength))) else {
            fatalError("missing actual catalog query")
        }
        var list = visionAudioIntentCatalog!
        list.responseRequestID = query.requestID
        receiveCatalog(Wire.decode(WindowList.self, from: Wire.encode(list))!, from: peer)
    }
    var microphoneAuthorization: UUID?
    var visionAudioPrivacyBlocked = false
    var microphoneStarts = 0, microphoneStops = 0
    var visionAudioTrustedHostKey: String? { context.hostKey }
    var visionAudioIntentContext: VisionRemoteAudioIntent.Context {
        var result = context
        if visionAudioPrivacyBlocked { result.protected = false }
        return result
    }
    init(_ key: String) {
        context = .init()
        context.hostKey = key
        context.scope = .init(connection: UUID(), window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
        context.connected = true; context.authenticated = true; context.foreground = true
        context.presented = true; context.inputBlocked = false; context.privacyVersion = 2
        context.nativeBindingReady = true
        context.protected = true; context.cleanupReady = true; context.playbackAvailable = true
        context.microphoneAvailable = true; context.recordPermissionGranted = true
    }
    func stopVisionMicrophoneActual() { microphoneStops += 1 }
    func toggleVisionMicrophone() { microphoneStarts += 1 }
    func startVisionMicrophoneAutomatically() { microphoneStarts += 1 }
}
