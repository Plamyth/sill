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
enum VisionAudioSharedHardware { static let shared = 0 }
final class VisionMicrophoneCapture {
    static var permissionCalls = 0, starts = 0, stops = 0, retries = 0
    static var delay = false, stopFails = false
    static var pending: [CheckedContinuation<Void,Never>] = []
    let permitted: () -> Bool
    let closeFrames: @Sendable () -> Void
    var emit: (@Sendable (IPadMicrophonePCMFrame) -> Void)?
    init(hardware: Int, owner: UUID, permitted: @escaping () -> Bool,
         closeFrames: @escaping @Sendable () -> Void, failed: @escaping (String) -> Void) {
        self.permitted = permitted; self.closeFrames = closeFrames
    }
    @MainActor func start(emit: @escaping @Sendable (IPadMicrophonePCMFrame) -> Void) async throws {
        guard permitted() else { throw CancellationError() }
        Self.starts += 1; Self.permissionCalls += 1
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
    func connectionLost(_ c: NWConnection, error: NWError) {}
}
func catalog(_ capability: MicrophoneCapability?, generation: UUID = UUID()) -> WindowList {
    let epoch = VideoEpoch(id: UUID(), inputGeneration: generation, source: .desktop,
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
let start = controls(peer).last!, scope = start.scope, grant = UUID()
check(start.operation == .start && VisionMicrophoneCapture.permissionCalls == 0, "explicit start waits for host before permission")
reply(client,peer:peer,id:UUID(),scope:scope,phase:.active,grant:grant)
reply(client,peer:other,id:start.requestID,scope:scope,phase:.active,grant:grant)
check(VisionMicrophoneCapture.starts == 0, "wrong request and peer cannot begin capture")
reply(client,peer:peer,id:start.requestID,scope:scope,phase:.active,grant:grant)
pump { client.microphonePhase == .live }
check(client.microphonePhase == .live && VisionMicrophoneCapture.permissionCalls == 1, "matching live grant starts one explicit capture")
let frame = IPadMicrophonePCMFrame(sequence: 1, frameCount: 960, pcm: Data(repeating: 0,count:1920))
let oldEmit = client.microphoneCapture!.emit!
oldEmit(frame)
check(frames(peer) == 1, "active scoped capture sends one frame")
client.toggleVisionMicrophone()
let stop = controls(peer).last!
oldEmit(frame)
check(stop.operation == .stop && stop.grantID == grant && frames(peer) == 1,
      "stop closes frames before scoped stop control")
reply(client,peer:peer,id:stop.requestID,scope:scope,phase:.off,grant:nil)
client.toggleVisionMicrophone()
let nextStart = controls(peer).last!
reply(client,peer:peer,id:nextStart.requestID,scope:scope,phase:.active,grant:UUID())
pump { client.microphonePhase == .live }
oldEmit(frame)
check(frames(peer) == 1, "late old producer cannot enter replacement capture")
client.microphoneCapture!.emit!(frame)
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
let pendingStart = controls(pendingPeer).last!
VisionMicrophoneCapture.delay = true
reply(pendingClient,peer:pendingPeer,id:pendingStart.requestID,scope:pendingStart.scope,phase:.active,grant:UUID())
pump { !VisionMicrophoneCapture.pending.isEmpty }
pendingClient.microphoneBackgrounded()
VisionMicrophoneCapture.delay = false
VisionMicrophoneCapture.pending.removeFirst().resume()
settle()
check(pendingClient.microphonePhase == .unavailable && pendingClient.microphoneCapture == nil && frames(pendingPeer) == 0,
      "permission continuation after background cannot open transmission")

var policy = IPadMicrophonePolicy()
_ = policy.setConnection(ObjectIdentifier(peer))
let list = catalog(capability)
_ = policy.observe(list,from:ObjectIdentifier(peer))
_ = policy.toggle(); let request = policy.startRequestID!, boundScope = policy.scope!
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
print("RESULT_ASSERTIONS \(checks)")
print("RESULT_FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
