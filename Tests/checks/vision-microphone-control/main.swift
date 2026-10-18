import Foundation
import Network
import os
import StreamProtocol

var checks = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL \(name)") }
}
func pump(_ until: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.015)) }
struct FakeFailure: LocalizedError { var errorDescription: String? { "injected capture cleanup failure" } }
struct InertHardware { var cleanupProblem: String? }
enum VisionAudioSharedHardware { static var shared = InertHardware() }
final class VisionMicrophoneCapture {
    static var permissionCalls = 0, starts = 0, stops = 0, retries = 0
    static var delay = false, stopFails = false
    static var pending: [CheckedContinuation<Void,Never>] = []
    let permitted: () -> Bool
    let closeFrames: @Sendable () -> Void
    var emit: (@Sendable ([IPadMicrophonePCMFrame]) -> Void)?
    init(hardware: InertHardware, owner: UUID, permitted: @escaping () -> Bool,
         closeFrames: @escaping @Sendable () -> Void, failed: @escaping (String) -> Void) {
        self.permitted = permitted; self.closeFrames = closeFrames
    }
    @MainActor func start(emit: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) async throws {
        guard permitted() else { throw CancellationError() }
        Self.starts += 1
        if Self.delay { await withCheckedContinuation { Self.pending.append($0) } }
        guard permitted() else { throw CancellationError() }
        self.emit = emit
    }
    func stop() throws {
        closeFrames(); Self.stops += 1
        if Self.stopFails { throw FakeFailure() }
        emit = nil
    }
    func retryCleanup() throws { Self.retries += 1; try stop() }
}
final class StreamClient {
    var connection: NWConnection?
    let visionAudioOwnerID = UUID()
    var microphonePhase: IPadMicrophonePolicy.Phase = .unavailable
    var microphoneCleanupProblem: String?
    var microphoneReceipt: MicrophoneReceipt?
    var microphonePolicy = IPadMicrophonePolicy()
    let microphoneFrames = IPadMicrophoneFrameGate()
    var microphoneCapture: VisionMicrophoneCapture?
    var microphoneCaptureToken: UUID?
    var microphoneAdmission = VisionMicrophoneAdmission(lease: VisionWindowLease(window: UUID()),
        scene: .active, applicationActive: true)
    var microphoneAuthorization: VisionMicrophoneAuthorization?
    var requestVisionMicrophonePermission: (@escaping (Bool) -> Void) -> Void = { completion in
        VisionMicrophoneCapture.permissionCalls += 1
        completion(true)
    }
    func connectionLost(_ c: NWConnection, error: NWError) {}
}
func catalog(_ capability: MicrophoneCapability?, generation: UUID = UUID()) -> WindowList {
    let epoch = VideoEpoch(id: UUID(), generation: generation.uuidString, source: .desktop,
                          geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
    return WindowList(macName: "Mac", windows: [], active: .desktop,
                      inputGeneration: generation.uuidString, videoEpoch: epoch, microphone: capability)
}
func controls(_ c: NWConnection) -> [MicrophoneControl] {
    c.sent.compactMap { bytes in
        guard StreamMessage.parseHeader(bytes)?.kind == .microphoneControl else { return nil }
        return Wire.decode(MicrophoneControl.self, from: Data(bytes.dropFirst(StreamMessage.headerLength)))
    }
}
func frames(_ c: NWConnection) -> Int { c.sent.filter { StreamMessage.parseHeader($0)?.kind == .microphoneFrame }.count }
func reply(_ client: StreamClient, peer: NWConnection, id: UUID, scope: MicrophoneScope, phase: MicrophoneState.Phase, grant: UUID?) {
    let state = MicrophoneState(requestID: id, scope: scope, phase: phase, grantID: grant)
    let data = Wire.encode(state)
    let header = StreamMessage.parseHeader(StreamMessage(kind: .microphoneState, timestamp: 0, isKeyframe: false, payload: data).serialized())!
    check(client.receiveMicrophone(header,data,from:peer), "microphone reply consumed")
    settle()
}
let peer = NWConnection(), other = NWConnection(), client = StreamClient()
client.connection = peer
client.microphoneSetConnection(peer)
client.toggleVisionMicrophone()
client.microphoneObserve(catalog(nil),from:peer)
client.toggleVisionMicrophone()
check(peer.sent.isEmpty && VisionMicrophoneCapture.permissionCalls == 0, "capnil and old host send no control or permission")
let capability = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())
client.microphoneObserve(catalog(capability),from:peer)
check(client.microphonePhase == .off && peer.sent.isEmpty && VisionMicrophoneCapture.starts == 0,
      "capability observation never starts microphone")
client.toggleVisionMicrophone()
pump { !controls(peer).isEmpty }
let start = controls(peer).last!, scope = start.scope, grant = UUID()
check(start.operation == .start && VisionMicrophoneCapture.permissionCalls == 1 && VisionMicrophoneCapture.starts == 0,
      "permission resolves before host start and capture waits for ACK")
reply(client,peer:peer,id:UUID(),scope:scope,phase:.active,grant:grant)
reply(client,peer:other,id:start.requestID,scope:scope,phase:.active,grant:grant)
check(VisionMicrophoneCapture.starts == 0 && client.microphoneCapture == nil && client.microphonePhase == .requesting, "wrong request and peer cannot begin capture")
reply(client,peer:peer,id:start.requestID,scope:scope,phase:.active,grant:grant)
pump { client.microphonePhase == .live }
check(client.microphonePhase == .live && VisionMicrophoneCapture.permissionCalls == 1, "matching live grant starts one explicit capture")
guard client.microphonePhase == .live else {
    print("RESULT_ASSERTIONS \(checks)"); print("RESULT_FAILURES \(max(1,failures))"); exit(1)
}
let frame = IPadMicrophonePCMFrame(sequence: 1, frameCount: 960, pcm: Data(repeating: 0,count:1920))
let oldEmit = client.microphoneCapture!.emit!
oldEmit([frame])
check(frames(peer) == 1, "active scoped capture sends one frame")
client.toggleVisionMicrophone()
let stop = controls(peer).last!
oldEmit([frame])
check(stop.operation == .stop && stop.grantID == grant && frames(peer) == 1,
      "stop closes frames before scoped stop control")
reply(client,peer:peer,id:stop.requestID,scope:scope,phase:.off,grant:nil)
client.toggleVisionMicrophone()
pump { controls(peer).last?.operation == .start }
let nextStart = controls(peer).last!
reply(client,peer:peer,id:nextStart.requestID,scope:scope,phase:.active,grant:UUID())
pump { client.microphonePhase == .live }
oldEmit([frame])
check(frames(peer) == 1, "late old producer cannot enter replacement capture")
client.microphoneCapture!.emit!([frame])
check(frames(peer) == 2, "replacement capture uses its own token")
VisionMicrophoneCapture.stopFails = true
client.toggleVisionMicrophone()
check(client.microphoneCleanupProblem != nil && client.microphoneCapture != nil, "failed cleanup retains exact capture object")
let beforeRetry = controls(peer).count, beforePermission = VisionMicrophoneCapture.permissionCalls
VisionMicrophoneCapture.stopFails = false
client.toggleVisionMicrophone()
check(VisionMicrophoneCapture.retries == 1 && client.microphoneCleanupProblem == nil &&
      controls(peer).count == beforeRetry && VisionMicrophoneCapture.permissionCalls == beforePermission,
      "explicit cleanup cannot grant permission or send a new start")
client.microphoneSetConnection(nil)

let pendingClient = StreamClient(), pendingPeer = NWConnection()
pendingClient.connection = pendingPeer; pendingClient.microphoneSetConnection(pendingPeer)
pendingClient.microphoneObserve(catalog(capability),from:pendingPeer)
pendingClient.toggleVisionMicrophone()
pump { !controls(pendingPeer).isEmpty }
let pendingStart = controls(pendingPeer).last!
VisionMicrophoneCapture.delay = true
reply(pendingClient,peer:pendingPeer,id:pendingStart.requestID,scope:pendingStart.scope,phase:.active,grant:UUID())
pump { !VisionMicrophoneCapture.pending.isEmpty }
pendingClient.microphoneBackgrounded()
VisionMicrophoneCapture.delay = false
VisionMicrophoneCapture.pending.removeFirst().resume()
settle()
check(pendingClient.microphonePhase == .stopping && pendingClient.microphoneCapture == nil && frames(pendingPeer) == 0,
      "capture continuation after background cannot open transmission")

var policy = IPadMicrophonePolicy()
_ = policy.setConnection(ObjectIdentifier(peer))
let list = catalog(capability)
_ = policy.observe(list,from:ObjectIdentifier(peer))
_ = policy.toggle(); let request = policy.startRequestID!, boundScope = policy.scope!
_ = policy.permissionResolved(true,requestID:request,scope:boundScope,from:ObjectIdentifier(peer))
_ = policy.receive(MicrophoneState(requestID:request,scope:boundScope,phase:.active,grantID:grant),from:ObjectIdentifier(peer))
_ = policy.captureStarted(requestID:request,grant:grant,from:ObjectIdentifier(peer))
let failed = policy.captureFailed(requestID:request,grant:grant,from:ObjectIdentifier(peer),reason:"injected live failure")
check(policy.phase == .failed("injected live failure") && failed.first == .closeFrames && failed.last == .stopCapture,
      "live native failure retires grant and closes transmission")

let sent = OSAllocatedUnfairLock(initialState: [Data]())
let gate = IPadMicrophoneFrameGate(send: { _,bytes,_ in sent.withLock { $0.append(bytes) } })
let oldID = UUID(), newID = UUID()
gate.open(connection:peer,scope:scope,grant:grant,captureID:oldID)
gate.open(connection:peer,scope:scope,grant:grant,captureID:newID)
gate.close(captureID:oldID)
gate.emit(frame,captureID:newID)
check(sent.withLock { $0.count == 1 }, "old scoped close cannot close a replacement grant")
gate.emit(frame,captureID:newID); gate.emit(frame,captureID:newID)
check(sent.withLock { $0.count == 2 }, "framegate limits pending network sends to two")
gate.close(captureID:newID); gate.emit(frame,captureID:newID)
check(sent.withLock { $0.count == 2 }, "current scoped close blocks all later frames")
let batched = OSAllocatedUnfairLock(initialState: [Data]())
let batchGate = IPadMicrophoneFrameGate(send: { _,bytes,_ in batched.withLock { $0.append(bytes) } })
batchGate.open(connection: peer, scope: scope, grant: grant, captureID: newID)
let burst = (1...5).map { IPadMicrophonePCMFrame(sequence: UInt64($0), frameCount: 960, pcm: frame.pcm) }
batchGate.emitBatch(burst, captureID: newID)
check(batched.withLock { $0.count == 1 }, "100ms burst uses one pending network batch")
var bytes = batched.withLock { $0.first! }, sequences: [UInt64] = []
while bytes.count >= StreamMessage.headerLength, let header = StreamMessage.parseHeader(bytes) {
    let length = StreamMessage.headerLength + header.payloadLength
    guard header.kind == .microphoneFrame, header.payloadLength <= MicrophoneWire.frameLimit,
          bytes.count >= length,
          let value = MicrophoneFrame(encoded: Data(bytes[StreamMessage.headerLength..<length])) else { break }
    sequences.append(value.sequence)
    bytes = Data(bytes.dropFirst(length))
}
check(bytes.isEmpty && sequences == [1,2,3,4,5], "framed batch preserves every100ms packet in original wire format")
batchGate.emitBatch(burst,captureID:newID); batchGate.emitBatch(burst,captureID:newID)
check(batched.withLock { $0.count == 2 }, "bounded pending count applies to complete hardware batches")
let boundaryBytes = OSAllocatedUnfairLock(initialState: [Data]())
let held = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
let boundary = IPadMicrophoneFrameGate(send: { _,bytes,done in
    boundaryBytes.withLock { $0.append(bytes) }; held.withLock { $0.append(done) }
})
boundary.open(connection:peer,scope:scope,grant:grant,captureID:newID)
boundary.emitBatch([],captureID:newID)
boundary.emitBatch([IPadMicrophonePCMFrame(sequence:1,frameCount:960,pcm:Data())],captureID:newID)
let maximum = (1...IPadMicrophonePCM.maxBatchPackets).map { IPadMicrophonePCMFrame(sequence:UInt64($0),frameCount:960,pcm:frame.pcm) }
boundary.emitBatch(maximum+[frame],captureID:newID)
check(boundaryBytes.withLock { $0.isEmpty }, "invalid empty and oversized batches consume no send slot")
boundary.emitBatch(maximum,captureID:newID)
check(boundaryBytes.withLock { $0.count == 1 && $0[0].count == IPadMicrophonePCM.maxBatchPackets * 2047 }, "maximum batch respects exact wire byte bound")
boundary.emitBatch(burst,captureID:newID)
let firstDone = held.withLock { $0[0] }
firstDone()
boundary.emitBatch(burst,captureID:newID)
check(boundaryBytes.withLock { $0.count == 3 }, "one batch completion restores exactly one send slot")
let staleDone = held.withLock { $0[1] }
boundary.close()
let replacementID = UUID()
boundary.open(connection:peer,scope:scope,grant:UUID(),captureID:replacementID)
boundary.emitBatch(burst,captureID:replacementID); boundary.emitBatch(burst,captureID:replacementID)
staleDone()
boundary.emitBatch(burst,captureID:replacementID)
check(boundaryBytes.withLock { $0.count == 5 }, "old completion cannot decrement replacement batch accounting")
boundary.close(captureID:replacementID)
boundary.emitBatch(burst,captureID:replacementID)
check(boundaryBytes.withLock { $0.count == 5 }, "stop blocks complete later batches")

final class AuthorizationFixture {
    let peer = NWConnection()
    let client = StreamClient()
    let list = catalog(MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID()))
    let lease: VisionWindowLease
    var callbacks: [(Bool) -> Void] = []
    init() {
        lease = client.microphoneAdmission.lease!
        client.connection = peer
        client.microphoneSetConnection(peer)
        client.microphoneObserve(list, from: peer)
        client.requestVisionMicrophonePermission = { [weak self] completion in self?.callbacks.append(completion) }
    }
    func restoreAdmission() {
        client.connection = peer
        client.microphoneSetConnection(peer)
        client.microphoneObserve(list, from: peer)
        client.microphoneSceneChanged(lease: lease, scene: .active)
        client.microphoneApplicationActive(true)
    }
    var starts: [MicrophoneControl] { controls(peer).filter { $0.operation == .start } }
}

let delayed = AuthorizationFixture(), capturesBeforePermission = VisionMicrophoneCapture.starts
delayed.client.toggleVisionMicrophone()
check(delayed.callbacks.count == 1 && delayed.starts.isEmpty && delayed.client.microphonePhase == .authorizing,
      "delayed OS permission emits no host start")
delayed.client.microphoneSceneChanged(lease: delayed.lease, scene: .inactive)
delayed.client.microphoneApplicationActive(false)
delayed.callbacks[0](true); settle()
delayed.callbacks[0](false); settle()
check(delayed.starts.isEmpty && VisionMicrophoneCapture.starts == capturesBeforePermission &&
      delayed.client.microphonePhase == .authorizing,
      "inactive stores first permission result without starting host or capture")
delayed.client.microphoneSceneChanged(lease: delayed.lease, scene: .active)
check(delayed.starts.isEmpty, "scene active alone cannot bypass UIApplication inactivity")
delayed.client.microphoneApplicationActive(true)
check(delayed.starts.count == 1 && delayed.callbacks.count == 1 && delayed.client.microphonePhase == .requesting,
      "original admission consumes stored permission once when fully active")
delayed.callbacks[0](true); settle()
check(delayed.starts.count == 1, "duplicate resolved permission cannot start host twice")
let delayedStart = delayed.starts[0]
delayed.client.microphoneSceneChanged(lease: delayed.lease, scene: .inactive)
reply(delayed.client, peer: delayed.peer, id: delayedStart.requestID, scope: delayedStart.scope, phase: .active, grant: UUID())
check(VisionMicrophoneCapture.starts == capturesBeforePermission && delayed.client.microphoneCapture == nil && frames(delayed.peer) == 0,
      "host ACK while inactive cannot begin capture or open frames")

let inactiveBoundary = AuthorizationFixture()
inactiveBoundary.client.toggleVisionMicrophone(); inactiveBoundary.callbacks[0](true); settle()
let inactiveStart = inactiveBoundary.starts[0], beforeInactiveACK = VisionMicrophoneCapture.starts
inactiveBoundary.client.microphoneAdmission.applicationActive = false
reply(inactiveBoundary.client, peer: inactiveBoundary.peer, id: inactiveStart.requestID,
      scope: inactiveStart.scope, phase: .active, grant: UUID())
check(inactiveBoundary.client.microphoneCapture == nil && VisionMicrophoneCapture.starts == beforeInactiveACK &&
      controls(inactiveBoundary.peer).last?.operation == .stop,
      "capture boundary rechecks active admission even before lifecycle reduction")

let deniedPermission = AuthorizationFixture()
deniedPermission.client.toggleVisionMicrophone()
deniedPermission.callbacks[0](false); settle()
check(deniedPermission.starts.isEmpty && deniedPermission.client.microphonePhase == .failed("iPad 마이크 권한이 필요합니다.") &&
      deniedPermission.client.microphoneCapture == nil, "denied OS permission never reaches host or capture")
deniedPermission.client.microphoneApplicationActive(true)
check(deniedPermission.callbacks.count == 1 && deniedPermission.starts.isEmpty,
      "foreground does not retry denied consent")

for event in ["cancel", "peer", "source", "window", "background", "scene-background"] {
    let fixture = AuthorizationFixture()
    fixture.client.toggleVisionMicrophone()
    let request = fixture.client.microphonePolicy.startRequestID!
    let callback = fixture.callbacks[0]
    switch event {
    case "cancel": fixture.client.toggleVisionMicrophone()
    case "peer":
        let replacement = NWConnection()
        fixture.client.connection = replacement
        fixture.client.microphoneSetConnection(replacement)
    case "source": fixture.client.microphoneObserve(catalog(capability), from: fixture.peer)
    case "window":
        fixture.client.microphoneSceneChanged(lease: VisionWindowLease(window: fixture.lease.window), scene: .active)
    case "background": fixture.client.microphoneBackgrounded()
    default: fixture.client.microphoneSceneChanged(lease: fixture.lease, scene: .background)
    }
    fixture.restoreAdmission()
    fixture.client.toggleVisionMicrophone()
    check(fixture.callbacks.count == 1 && fixture.starts.isEmpty && !fixture.client.visionMicrophoneCanStart,
          "\(event) retains outstanding OS slot and prevents concurrent permission prompts")
    callback(true); settle()
    check(fixture.starts.isEmpty && fixture.client.microphoneAuthorization == nil,
          "\(event) drains delayed permission without starting host")
    fixture.client.toggleVisionMicrophone()
    check(fixture.callbacks.count == 2 && fixture.client.microphonePolicy.startRequestID != request,
          "\(event) permits only a fresh explicit toggle after request drain")
    callback(true); settle()
    check(fixture.starts.isEmpty && fixture.client.microphoneAuthorization != nil,
          "\(event) old duplicate cannot consume replacement authorization")
    fixture.callbacks[1](false); settle()
}

let unavailable = AuthorizationFixture()
unavailable.client.toggleVisionMicrophone()
VisionAudioSharedHardware.shared.cleanupProblem = "inert cleanup quarantine"
unavailable.callbacks[0](true); settle()
check(unavailable.starts.isEmpty && unavailable.client.microphoneCapture == nil &&
      unavailable.client.microphonePhase == .failed("다른 기능에서 이미 마이크를 사용 중입니다."),
      "hardware cleanup is rechecked when permission resolves")
VisionAudioSharedHardware.shared.cleanupProblem = nil

let lateCapture = AuthorizationFixture()
lateCapture.client.toggleVisionMicrophone(); lateCapture.callbacks[0](true); settle()
let lateStart = lateCapture.starts[0], lateGrant = UUID()
VisionMicrophoneCapture.delay = true
reply(lateCapture.client, peer: lateCapture.peer, id: lateStart.requestID, scope: lateStart.scope, phase: .active, grant: lateGrant)
pump { !VisionMicrophoneCapture.pending.isEmpty }
lateCapture.client.microphoneSceneChanged(lease: lateCapture.lease, scene: .inactive)
VisionMicrophoneCapture.delay = false
VisionMicrophoneCapture.pending.removeFirst().resume(); settle()
check(lateCapture.client.microphoneCapture == nil && frames(lateCapture.peer) == 0,
      "capture readiness after inactivity cannot open frames")

let readinessBoundary = AuthorizationFixture()
readinessBoundary.client.toggleVisionMicrophone(); readinessBoundary.callbacks[0](true); settle()
let readinessStart = readinessBoundary.starts[0]
VisionMicrophoneCapture.delay = true
reply(readinessBoundary.client, peer: readinessBoundary.peer, id: readinessStart.requestID,
      scope: readinessStart.scope, phase: .active, grant: UUID())
pump { !VisionMicrophoneCapture.pending.isEmpty }
readinessBoundary.client.microphoneAdmission.scene = .inactive
VisionMicrophoneCapture.delay = false
VisionMicrophoneCapture.pending.removeFirst().resume(); settle()
check(readinessBoundary.client.microphoneCapture == nil && frames(readinessBoundary.peer) == 0 &&
      controls(readinessBoundary.peer).last?.operation == .stop,
      "capture completion rechecks admission and retires host before opening frames")

let hostCleanup = AuthorizationFixture()
hostCleanup.client.toggleVisionMicrophone(); hostCleanup.callbacks[0](true); settle()
let cleanupStart = hostCleanup.starts[0]
reply(hostCleanup.client, peer: hostCleanup.peer, id: cleanupStart.requestID, scope: cleanupStart.scope, phase: .cleanupFailed, grant: nil)
hostCleanup.client.toggleVisionMicrophone()
hostCleanup.client.microphoneBackgrounded()
check(hostCleanup.client.microphonePhase == .cleanupRequired && hostCleanup.starts.count == 1 && hostCleanup.callbacks.count == 1,
      "host cleanupRequired survives toggle and background without reauthorization")
hostCleanup.restoreAdmission()
check(hostCleanup.client.microphonePhase == .off && hostCleanup.starts.count == 1 && hostCleanup.callbacks.count == 1,
      "fresh host catalog recovers cleanup without claiming recording restarted")
hostCleanup.client.toggleVisionMicrophone()
check(hostCleanup.callbacks.count == 2 && hostCleanup.starts.count == 1,
      "host cleanup recovery still requires explicit permission before next start")
hostCleanup.callbacks[1](false); settle()

print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
