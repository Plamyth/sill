import Foundation
import CoreFoundation
import Network
import StreamProtocol

var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ witness: String) {
    guard value() else { print("FAIL \(witness)"); exit(1) }
    assertions += 1
    print("PASS \(witness)")
}
let geometry = VideoEpoch.Geometry(x: 0, y: 0, width: 800, height: 600)
func epoch(_ generation: String = "generation-A", source: StreamSource = .window(42), width: Int = 800) -> VideoEpoch {
    VideoEpoch(generation: generation, source: source, geometry: geometry, width: width, height: 600)
}
func catalog(_ epoch: VideoEpoch?, source: StreamSource = .window(42), generation: String? = "generation-A", modern: Int? = 1) -> WindowList {
    WindowList(macName: "Fixture", windows: [], active: source, inputGeneration: generation,
               presentationInput: modern, videoEpoch: epoch)
}
func message(_ kind: StreamMessageKind, _ payload: Data = Data(), key: Bool = false) -> StreamMessage {
    StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: key, payload: payload)
}
func messages(_ peer: NWConnection) -> [StreamMessage] {
    peer.sent.map { bytes in
        let header = StreamMessage.parseHeader(bytes)!
        return StreamMessage(kind: header.kind, timestamp: header.timestamp, isKeyframe: header.isKeyframe,
                             payload: Data(bytes.dropFirst(StreamMessage.headerLength)))
    }
}
func inputs(_ peer: NWConnection) -> [SourceInput] {
    messages(peer).filter { $0.kind == .input }.compactMap { Wire.decode(SourceInput.self, from: $0.payload) }
}
let a = epoch(), b = epoch(), other = epoch("generation-B", source: .window(99))
let ps = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])])
let idr = Data([0, 0, 0, 2, 0x26, 1]), delta = Data([0, 0, 0, 2, 0x02, 1])
check(a.id != b.id && a.generation == b.generation, "same-source restart keeps source generation and changes pipeline ID")
check(!VideoEpoch.Geometry(x: .infinity, y: 0, width: 1, height: 1).isValid && !VideoEpoch.Geometry(x: 0, y: 0, width: 0, height: 1).isValid, "nonfinite and empty geometry rejected")
check(VisionInputBinding(catalog: catalog(a)).capture(.text("closed")) == nil, "catalog alone cannot authorize epoch input")
check(VisionInputBinding(catalog: catalog(nil)) == .awaitingPresentation(nil), "missing epoch never downgrades capable host")
check(VisionInputBinding(catalog: catalog(a, source: .desktop)) == .awaitingPresentation(nil), "source metadata mismatch closes native admission")
check(VisionInputBinding(catalog: catalog(a, generation: "wrong")) == .awaitingPresentation(nil), "generation metadata mismatch closes native admission")
let payload = PresentationMedia.encode(epoch: a.id, media: ps.encoded())
check(PresentationMedia.decode(payload, kind: .epochParameterSets)?.epoch == a.id, "UUID prefix round trips without JSON media")
check(PresentationMedia.decode(Data(payload.prefix(16)), kind: .epochParameterSets) == nil, "empty tagged payload refused")
check(PresentationMedia.decode(payload + Data([0]), kind: .epochParameterSets) == nil, "parameter trailing bytes refused")
let badPS = ParameterSets(nalUnitHeaderLength: 3, sets: ps.sets)
check(PresentationMedia.decode(PresentationMedia.encode(epoch: a.id, media: badPS.encoded()), kind: .epochParameterSets) == nil, "unsupported NAL length refused")
check(PresentationMedia.decode(PresentationMedia.encode(epoch: a.id, media: Data([4, 255])), kind: .epochParameterSets) == nil, "malformed parameter lengths refused")
check(PresentationMedia.validFrame(idr, nalLength: 4, keyframe: true) && !PresentationMedia.validFrame(delta, nalLength: 4, keyframe: true), "tag keyframe flag requires actual IDR NAL")
check(!PresentationMedia.validFrame(Data([0, 0, 0, 9, 0x26, 1]), nalLength: 4, keyframe: true), "truncated frame NAL refused")
check(PresentationMedia.decode(payload, kind: .parameterSets) == nil, "untagged kind cannot parse as tagged codec")
check(StreamMessage.hostPayloadLimit(for: .epochFrame) == StreamMessage.maxFramePayload, "tagged frames retain frame-sized reader cap")
check(StreamMessage.hostPayloadLimit(for: .epochParameterSets) == StreamMessage.maxOtherHostPayload, "tagged parameters retain control-sized reader cap")

let readerPeer = NWConnection()
let largeTagged = message(.epochFrame, Data(repeating: 1, count: StreamMessage.maxOtherHostPayload + 1), key: true)
readerPeer.inbound = largeTagged.serialized()
var readFrames = 0, oversized = false
let reader = MessageReader(connection: readerPeer, stillReads: { true }, onBytes: { _ in },
    onMessage: { header, data in if header.kind == .epochFrame && data.count == largeTagged.payload.count { readFrames += 1 } },
    onEnd: { if case .tooBig = $0 { oversized = true } })
reader.start()
check(readFrames == 1 && !oversized, "actual MessageReader accepts tagged frame beyond control cap")
let probe = ProbeCap(), probePeer = NWConnection()
probe.receive(StreamMessage.parseHeader(largeTagged.serialized())!, c: probePeer)
check(probe.accepted == 1 && probePeer.state == .ready, "actual move probe accepts tagged frame beyond control cap")
let oversizedControl = message(.epochParameterSets, Data(repeating: 0, count: StreamMessage.maxOtherHostPayload + 1))
probe.receive(StreamMessage.parseHeader(oversizedControl.serialized())!, c: probePeer)
check(probe.accepted == 1 && probePeer.state == .cancelled, "move probe still refuses oversized tagged parameters")

let host = MediaHost(), legacy = NWConnection(), modern = NWConnection(), remote = NWConnection()
host.add(legacy, remote: false, modern: false)
host.add(modern, remote: false, modern: true)
host.add(remote, remote: true, modern: true)
host.prepareVideo(a); host.drain()
host.broadcast(message(.parameterSets, ps.encoded(), key: true), epoch: a.id)
host.broadcast(message(.frame, idr, key: true), epoch: a.id); host.drain()
check(legacy.sent.isEmpty && modern.sent.isEmpty && remote.sent.isEmpty, "precommit encoder media has zero client effects")
var keyframeRequests = 0
var keyframeSawCatalog = false
host.commitVideo(a, catalog: message(.windowList, Wire.encode(catalog(a)))) { keyframeRequests += 1; keyframeSawCatalog = messages(modern).first?.kind == .windowList }
host.drain()
check(keyframeRequests == 1 && keyframeSawCatalog && messages(modern).first?.kind == .windowList, "commit publishes catalog before keyframe request")
let preHello = Wire.decode(WindowList.self, from: messages(legacy).first!.payload)!
check(preHello.presentationInput == 1 && preHello.videoEpoch == a, "first catalog advertises host capability before peer Hello")
host.broadcast(message(.parameterSets, ps.encoded(), key: true), epoch: a.id)
host.broadcast(message(.frame, idr, key: true), epoch: a.id); host.drain()
check(messages(legacy).filter { $0.kind == .frame }.count == 1 && !messages(legacy).contains { $0.kind == .epochFrame || $0.kind == .epochParameterSets }, "legacy peer receives ordinary frame once")
check(messages(modern).filter { $0.kind == .epochFrame }.count == 1 && !messages(modern).contains { $0.kind == .frame || $0.kind == .parameterSets }, "modern peer receives tagged frame once")
check(messages(remote).filter { $0.kind == .epochFrame }.count == 1 && messages(remote).contains { $0.kind == .epochParameterSets } && messages(remote).filter { $0.kind == .epochParameterSets }.allSatisfy { PresentationMedia.decode($0.payload, kind: $0.kind)?.epoch == a.id }, "remote pacing and cached parameters retain epoch")
let beforeStale = modern.sent.count
host.prepareVideo(b); host.drain()
host.broadcast(message(.frame, idr, key: true), epoch: a.id); host.drain()
host.commitVideo(b, catalog: message(.windowList, Wire.encode(catalog(b)))) { keyframeRequests += 1 }; host.drain()
host.broadcast(message(.frame, idr, key: true), epoch: a.id)
host.broadcast(message(.frame, idr, key: true)); host.drain()
check(modern.sent.count == beforeStale + 1, "stale callback cannot bypass missing keyframe state")
host.broadcast(message(.frame, idr, key: true), epoch: b.id); host.drain()
check(modern.sent.count == beforeStale + 1, "new pipeline cannot reuse cached old parameter sets")
host.broadcast(message(.parameterSets, ps.encoded(), key: true), epoch: b.id)
host.broadcast(message(.frame, idr, key: true), epoch: b.id); host.drain()
check(PresentationMedia.decode(messages(modern).last!.payload, kind: .epochFrame)?.epoch == b.id, "same-source restart emits its own epoch")
let committedCount = modern.sent.count
host.broadcast(message(.parameterSets, ps.encoded(), key: true), epoch: a.id)
host.broadcast(message(.frame, idr, key: true), epoch: a.id)
host.broadcast(message(.frame, idr, key: true)); host.drain()
check(modern.sent.count == committedCount, "stale callback and missing epoch cannot relabel old media")
host.queue.sync { host.clients[ObjectIdentifier(remote)]!.needsKeyframe = true }
host.broadcast(message(.frame, idr, key: true), epoch: b.id); host.drain()
check(messages(remote).suffix(2).map(\.kind) == [.epochParameterSets, .epochFrame] && messages(remote).suffix(2).allSatisfy { PresentationMedia.decode($0.payload, kind: $0.kind)?.epoch == b.id }, "remote retransmit uses current cached parameters with matching IDR")
host.resetForNewStream(); host.drain()
let stopped = modern.sent.count
host.broadcast(message(.frame, idr, key: true), epoch: b.id); host.drain()
check(modern.sent.count == stopped, "stopped stream has no valid epoch")

let display = EpochDisplay(), owner = NSObject(), foreign = NSObject()
let ownerID = ObjectIdentifier(owner)
var readyTickets: [VisionPresentation.Ticket] = []
display.onPresentation = { if let ticket = $0 { readyTickets.append(ticket) } }
display.setPresentation(epoch: a, peer: ownerID, modern: true)
let layerA = display.nativeLayer!, ticketA = display.presentation.ticket!
display.receiveParameters(ps, epoch: a.id, peer: ownerID)
check(display.pointerVideoSize == CGSize(width: 800, height: 600), "native format dimensions publish synchronously before readiness")
layerA.isReadyForDisplay = true
display.readPresentation(ticketA)
check(display.presentation.admitted == nil && !display.presentationShield.isHidden, "framework readiness before IDR cannot open shield")
display.receiveFrame(idr, keyframe: true, epoch: a.id, peer: ObjectIdentifier(foreign))
check(layerA.sampleBufferRenderer.samples == 0, "foreign peer cannot enqueue current epoch")
display.receiveFrame(idr, keyframe: true, epoch: UUID(), peer: ownerID)
check(layerA.sampleBufferRenderer.samples == 0, "unknown UUID cannot enqueue current epoch")
display.receiveFrame(idr, keyframe: true, epoch: a.id, peer: ownerID)
check(display.presentation.admitted == ticketA && display.presentationShield.isHidden, "matching IDR and framework-ready layer open logical admission")
display.receiveParameters(ps, epoch: a.id, peer: ownerID)
check(display.nativeLayer === layerA && display.presentation.ticket == ticketA, "healthy repeated parameter sets preserve current layer")
display.setPresentation(epoch: b, peer: ownerID, modern: true)
check(display.nativeLayer == nil && display.retiring?.layer === layerA && !display.presentationShield.isHidden, "new epoch retires old image behind closed shield")
display.readPresentation(ticketA)
check(display.presentation.admitted == nil, "obsolete ticket cannot reopen retired layer")
let last = epoch()
for _ in 0..<12 { display.setPresentation(epoch: epoch(), peer: ownerID, modern: true) }
display.setPresentation(epoch: last, peer: ownerID, modern: true)
check(display.nativeLayer == nil && FakeRenderer.flushes.count == 1, "rapid resets coalesce behind one retiring decoder")
display.receiveParameters(ps, epoch: last.id, peer: ownerID)
display.receiveFrame(idr, keyframe: true, epoch: last.id, peer: ownerID)
FakeRenderer.finish()
let latestLayer = display.nativeLayer!, latestTicket = display.presentation.ticket!
check(latestLayer !== layerA && latestTicket.epoch == last && latestLayer.sampleBufferRenderer.samples == 1, "retirement completion builds only latest requested epoch")
display.readPresentation(ticketA)
check(display.presentation.admitted == nil, "old layer ready receipt cannot authorize new layer")
latestLayer.isReadyForDisplay = true
display.readPresentation(latestTicket)
check(display.presentation.admitted == latestTicket, "new layer requires its own framework receipt")
display.setPresentationForeground(false)
check(display.presentation.admitted == nil && !display.presentationShield.isHidden, "background revokes permission and picture")
FakeRenderer.finish(); display.setPresentationForeground(true)
check(display.presentation.admitted == nil && display.presentation.ticket?.id != latestTicket.id, "foreground creates fresh lifecycle ticket without recycling receipt")
display.window = nil; display.invalidateNativeMedia(); FakeRenderer.finish()
check(display.nativeLayer == nil && display.presentation.admitted == nil, "detached view cannot recreate decoder or admission")
display.window = NSObject(); display.rebuildNativeLayer()
let mismatch = epoch(width: 801)
display.setPresentation(epoch: mismatch, peer: ownerID, modern: true); FakeRenderer.finish()
display.receiveParameters(ps, epoch: mismatch.id, peer: ownerID)
check(display.formatDescription == nil && display.presentation.admitted == nil, "coded dimensions mismatch revokes epoch before IDR")
FakeRenderer.finish()
display.setPresentation(epoch: a, peer: ownerID, modern: true); FakeRenderer.finish()
display.receiveParameters(ps, epoch: a.id, peer: ownerID)
display.receiveFrame(idr, keyframe: true, epoch: a.id, peer: ownerID)
let failLayer = display.nativeLayer!, failTicket = display.presentation.ticket!
failLayer.status = .failed; failLayer.isReadyForDisplay = true
display.readPresentation(failTicket)
check(display.presentation.admitted == nil && display.nativeLayer == nil, "decoder failure revokes ready notification")
FakeRenderer.finish()

let formatBoundary = EpochDisplay()
formatBoundary.setPresentation(epoch: a, peer: ownerID, modern: true)
formatBoundary.receiveParameters(ps, epoch: a.id, peer: ownerID)
formatBoundary.setPresentation(epoch: b, peer: ownerID, modern: true)
formatBoundary.receiveParameters(ps, epoch: b.id, peer: ownerID)
formatBoundary.receiveFrame(idr, keyframe: true, epoch: b.id, peer: ownerID)
check(formatBoundary.pendingNativeIDR != nil, "format-change precondition retains bounded IDR during retirement")
var changedSets = ps.sets
changedSets[1].append(0x01)
let changedParameters = ParameterSets(nalUnitHeaderLength: 4, sets: changedSets)
formatBoundary.receiveParameters(changedParameters, epoch: b.id, peer: ownerID)
check(formatBoundary.pendingNativeIDR == nil, "pending keyframe cannot outlive its parameter sets")
FakeRenderer.finish()
check(formatBoundary.waitingForKeyframe, "replacement format waits for a fresh matching IDR")

let client = StreamClient(), peer = NWConnection()
client.connection = peer
_ = client.catalog(catalog(a), from: peer); client.queue.sync {}
client.sendInput(.text("before ready")); client.queue.sync {}
check(inputs(peer).isEmpty, "actual native send blocked before layer receipt")
let identity = NSObject()
var presentation = VisionPresentation()
presentation.begin(epoch: a, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(identity))
let obsolete = presentation.ticket!
presentation.begin(epoch: b, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(identity))
let waitingTicket = presentation.ticket!
presentation.enqueuedIDR(waitingTicket)
presentation.observe(obsolete, ready: true, healthy: true, attached: true, foreground: true)
check(presentation.admitted == nil, "obsolete lifecycle notification cannot advance replacement state")
presentation.begin(epoch: a, peer: ObjectIdentifier(peer), layer: ObjectIdentifier(identity))
let ticket = presentation.ticket!
client.ready(ticket)
client.sendInput(.key(hidUsage: 4, down: true, modifiers: 0)); client.queue.sync {}
check(inputs(peer).last?.videoEpoch == a.id, "actual native submission carries presented epoch")
client.link.hold(peer)
client.sendInput(.text("held A")); client.queue.sync {}
let cancelEntered = DispatchSemaphore(value: 0), cancelResume = DispatchSemaphore(value: 0)
client.queue.async { cancelEntered.signal(); cancelResume.wait() }; cancelEntered.wait()
_ = client.catalog(catalog(b), from: peer)
_ = client.link.unhold(peer)
let heldWasRejected = !inputs(peer).contains { $0.event == .text("held A") }
cancelResume.signal(); client.queue.sync {}
check(heldWasRejected, "held SessionLink flush rejects revoked permit")
check(inputs(peer).last?.event == .key(hidUsage: 4, down: false, modifiers: 0) && inputs(peer).last?.videoEpoch == a.id, "owed terminal release retains original epoch after revocation")
_ = client.catalog(catalog(nil, modern: nil), from: peer)
client.sendInput(.text("downgrade")); client.queue.sync {}
check(client.visionInputBinding == .awaitingPresentation(nil) && !inputs(peer).contains { $0.event == .text("downgrade") }, "confirmed modern host cannot recover through metadata loss")
let ahead = StreamClient(), aheadPeer = NWConnection()
ahead.connection = aheadPeer
_ = ahead.catalog(catalog(a), from: aheadPeer); ahead.queue.sync {}
ahead.observe(catalog(b), from: aheadPeer)
ahead.ready(VisionPresentation.Ticket(epoch: a, peer: ObjectIdentifier(aheadPeer), layer: ObjectIdentifier(identity)))
ahead.sendInput(.text("obsolete-ready")); ahead.queue.sync {}
check(inputs(aheadPeer).isEmpty, "network catalog scope prevents obsolete main readiness from reopening permit")
let delayed = StreamClient(), delayedPeer = NWConnection()
delayed.connection = delayedPeer
_ = delayed.catalog(catalog(a), from: delayedPeer); delayed.queue.sync {}
delayed.ready(VisionPresentation.Ticket(epoch: a, peer: ObjectIdentifier(delayedPeer), layer: ObjectIdentifier(identity)))
let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
delayed.queue.async { entered.signal(); resume.wait() }; entered.wait()
delayed.sendInput(.text("queued old epoch"))
_ = delayed.catalog(catalog(b), from: delayedPeer)
resume.signal(); delayed.queue.sync {}
check(inputs(delayedPeer).isEmpty, "same-peer queued submission rechecks permit after revocation")
let nextPeer = NWConnection(); client.connection = nextPeer
_ = client.catalog(catalog(nil, modern: nil), from: nextPeer)
check(client.visionInputBinding == .scoped(generation: "generation-A"), "genuine old host retains explicit weaker compatibility")

let receiver = FrameReceiver(), mediaPeer = NWConnection()
receiver.connection = mediaPeer
receiver.visionWireBinding = (ObjectIdentifier(mediaPeer), .awaitingPresentation(a))
let taggedPS = message(.epochParameterSets, payload)
receiver.receive(StreamMessage.parseHeader(taggedPS.serialized())!, data: taggedPS.payload, peer: mediaPeer)
let taggedFrame = message(.epochFrame, PresentationMedia.encode(epoch: a.id, media: idr), key: true)
let frameHeader = StreamMessage.parseHeader(taggedFrame.serialized())!
receiver.receive(frameHeader, data: taggedFrame.payload, peer: mediaPeer)
check(receiver.frameCounter == 1 && receiver.frameAgeSamples.count == 1, "tagged current frame contributes existing link statistics")
receiver.receive(frameHeader, data: PresentationMedia.encode(epoch: b.id, media: idr), peer: mediaPeer)
receiver.receive(frameHeader, data: PresentationMedia.encode(epoch: a.id, media: delta), peer: mediaPeer)
check(receiver.frameCounter == 1, "stale and malformed tagged frames do not affect accounting")

let gatedHost = GeometryHost(), gatedPeer = NWConnection()
gatedHost.videoEpoch = a
_ = gatedHost.inputFence.join(ObjectIdentifier(gatedPeer), source: a.source, switching: false)
gatedHost.inputFence.negotiate(ObjectIdentifier(gatedPeer), supportsScoped: true)
func hostInput(_ event: InputEvent, generation: String, epoch: UUID?) -> StreamMessage {
    StreamMessage(kind: .input, timestamp: 0, isKeyframe: false,
                  payload: Wire.encode(SourceInput(event: event, generation: generation, videoEpoch: epoch)), requiresPresentation: true)
}
gatedHost.receive(hostInput(.text("missing"), generation: a.generation, epoch: nil), from: gatedPeer)
gatedHost.receive(hostInput(.text("wrong"), generation: "wrong", epoch: a.id), from: gatedPeer)
gatedHost.receive(hostInput(.text("unknown"), generation: a.generation, epoch: UUID()), from: gatedPeer)
check(gatedHost.focusEffects == 0 && gatedHost.injector.output.isEmpty, "actual modern input gate rejects missing epoch and metadata mismatch before focus")
gatedHost.receive(hostInput(.key(hidUsage: 4, down: true, modifiers: 0), generation: a.generation, epoch: a.id), from: gatedPeer)
check(gatedHost.focusEffects == 1 && gatedHost.injector.output.count == 1, "actual modern input gate admits exact current epoch")
gatedHost.videoEpoch = b
gatedHost.receive(hostInput(.key(hidUsage: 4, down: false, modifiers: 0), generation: a.generation, epoch: a.id), from: gatedPeer)
check(gatedHost.injector.output.last?.1.isNull == true && gatedHost.focusEffects == 1, "actual host old epoch terminal exemption releases without focus")

let hostGeometry = GeometryHost(), device = NSObject()
hostGeometry.videoEpoch = a
hostGeometry.rectCache = (42, CGRect(x: 99, y: 99, width: 800, height: 600), CFAbsoluteTimeGetCurrent())
let inputA = SourceInput(event: .text("geometry"), generation: a.generation, videoEpoch: a.id)
check(hostGeometry.presentationInputRect(inputA) == LiveGeometry.window, "modern geometry bypasses cached source rectangle")
hostGeometry.deliver(.key(hidUsage: 9, down: true, modifiers: 0), in: LiveGeometry.window!, from: ObjectIdentifier(device), epoch: a)
hostGeometry.holdUntil = CFAbsoluteTimeGetCurrent() + 100
hostGeometry.deliver(.text("held geometry"), in: LiveGeometry.window!, from: ObjectIdentifier(device), epoch: a)
LiveGeometry.window = CGRect(x: 10, y: 0, width: 800, height: 600)
hostGeometry.releaseHeldInput()
check(hostGeometry.injector.output.count == 1 && hostGeometry.videoEpoch == nil, "host activation queue rechecks current geometry before injection")
_ = hostGeometry.presentationInputRect(inputA); drainMain()
check(hostGeometry.selections.count == 1 && hostGeometry.selections.first?.0 == a.source && hostGeometry.selections.first?.1 == false, "geometry invalidation schedules one same-source restart without focus")
hostGeometry.applyAdmittedInput(.key(hidUsage: 9, down: false, modifiers: 0), rect: .zero, device: ObjectIdentifier(device), epoch: a)
check(hostGeometry.injector.output.last?.1.isNull == true, "old epoch owed host terminal uses null release path")
LiveGeometry.window = nil
check(hostGeometry.currentSourceRect(fresh: true) == nil && hostGeometry.currentSourceRect() != nil, "missing live window cannot fall back to cached modern geometry")
let staged = GeometryHost()
staged.virtualDisplay = true
staged.stage.isStaged = true
staged.stage.captureRectOnScreen = CGRect(x: 0, y: 0, width: 800, height: 600)
let stagedEpoch = VideoEpoch(generation: "generation-A", source: .window(42), geometry: geometry,
                             width: 800, height: 600, windowGeometry: geometry)
staged.videoEpoch = stagedEpoch
LiveGeometry.window = CGRect(x: 20, y: 0, width: 800, height: 600)
check(staged.presentationInputRect(SourceInput(event: .text("staged"), generation: stagedEpoch.generation, videoEpoch: stagedEpoch.id)) == nil,
      "staged capture crop cannot hide changed live window bounds")
print("RESULT_ASSERTIONS \(assertions)")
