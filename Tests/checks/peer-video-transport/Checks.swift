var failures = 0
var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !value() { failures += 1; print("FAIL: \(name)") }
}
func msg(_ kind: StreamMessageKind, _ payload: Data = Data([0, 0, 0, 2, 38, 1]), key: Bool = true) -> StreamMessage {
    StreamMessage(kind: kind, timestamp: 1, isKeyframe: key, payload: payload)
}
func epoch(_ window: UInt32) -> VideoEpoch {
    VideoEpoch(generation: UUID().uuidString, source: .window(window), geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
}
func catalog(_ epoch: VideoEpoch?) -> StreamMessage {
    var list = WindowList(macName: "fixture", windows: [], active: epoch?.source ?? .none)
    list.videoEpoch = epoch; list.inputGeneration = epoch?.generation
    return msg(.windowList, Wire.encode(list))
}
let sets = ParameterSets(nalUnitHeaderLength: 4, sets: [Data([64,1]), Data([66,1]), Data([68,1])]).encoded()
let tagged = msg(.epochFrame, PresentationMedia.encode(epoch: UUID(), media: Data([0,0,0,2,38,1])))
let server = StreamServer()
let a = NWConnection(), b = NWConnection(), legacy = NWConnection()
server.add(a); server.add(b, remote: true); server.add(legacy, modern: false)
server.send(tagged, to: a)
server.send(each: [(b, tagged)])
server.flush()
check(a.sent.isEmpty && b.sent.isEmpty, "generic tagged media cannot bypass unassigned lane")
// PEER_FLAG
func bind(_ c: NWConnection) async { let ok = await server.enablePeerVideo(for: c); check(ok, "peer lane assigned") }
func start(_ c: NWConnection, _ e: VideoEpoch, _ admission: SourcePublicationAdmission) {
    server.sendPeerCatalog(catalog(nil), to: c, admission: admission)
    server.preparePeerVideo(e, for: c, admission: admission)
    server.commitPeerVideo(e, catalog: catalog(e), admission: admission, to: c, requestKeyframe: {})
    server.sendPeerVideo(msg(.parameterSets, sets), epoch: e.id, to: c)
    server.sendPeerVideo(msg(.frame), epoch: e.id, to: c)
    server.flush()
}
func runPeers() async {
    let absent = NWConnection()
    let denied = await server.enablePeerVideo(for: absent)
    check(!denied, "unregistered connection cannot acquire a lane")
    let closed = NWConnection(); closed.state = .cancelled; server.add(closed)
    let closedDenied = await server.enablePeerVideo(for: closed)
    check(!closedDenied, "non-ready connection cannot acquire a lane")
    await bind(a); await bind(b)
    let ea = epoch(1), eb = epoch(2)
    let aa = SourcePublicationAdmission(), ab = SourcePublicationAdmission()
    server.preparePeerVideo(ea, for: a, admission: aa)
    server.sendPeerVideo(msg(.parameterSets, sets), epoch: ea.id, to: a)
    server.sendPeerVideo(msg(.frame), epoch: ea.id, to: a)
    server.flush()
    check(a.sent.isEmpty, "preparing epoch cannot publish media before catalog commit")
    // Return to stopped before exercising the initial peer catalog.
    server.resetPeerVideo(for: a, expectedEpoch: ea.id)
    server.flush()
    start(a, ea, aa); start(b, eb, ab)
    check(a.sent.compactMap(StreamMessage.parseHeader).map(\.kind) == [.windowList,.windowList,.epochParameterSets,.epochParameterSets,.epochFrame], "A catalog before parameter sets and keyframe")
    check(b.sent.compactMap(StreamMessage.parseHeader).last?.kind == .epochFrame, "B sends own keyframe")
    let ac = a.sent.count, bc = b.sent.count
    server.sendPeerCatalog(catalog(ea), to: b, admission: ab)
    server.sendMicrophoneCatalog(catalog(ea), to: b, grant: HostLocalOwnerGrant(epoch: ea.id, fingerprint: Data([1])), admission: ab)
    server.flush()
    check(b.sent.count == bc, "foreign catalog and microphone epoch cannot overwrite B")
    server.prepareVideo(epoch(9)); server.resetForNewStream()
    server.commitVideo(ea, catalog: catalog(ea), admission: SourcePublicationAdmission(), requestKeyframe: {})
    server.broadcast(msg(.parameterSets, sets), epoch: ea.id)
    server.broadcast(msg(.frame), epoch: ea.id)
    server.broadcast(tagged)
    server.sendCatalog(catalog(ea), to: b, admission: SourcePublicationAdmission())
    server.send(tagged, to: a); server.send(each: [(b, tagged)])
    server.flush()
    check(a.sent.count == ac && b.sent.count == bc, "global and generic routes cannot overwrite peer lanes")
    server.sendPeerVideo(msg(.frame), epoch: ea.id, to: b)
    server.flush()
    check(b.sent.count == bc, "A epoch cannot send to B")
    var earlyAsked = 0
    server.commitPeerVideo(ea, catalog: catalog(eb), admission: aa, to: a, requestKeyframe: { earlyAsked += 1 })
    server.flush()
    check(earlyAsked == 0 && a.sent.count == ac, "mismatched catalog cannot commit or request a keyframe")
    let newer = epoch(3), fresh = SourcePublicationAdmission()
    aa.invalidate()
    server.preparePeerVideo(newer, for: a, admission: fresh)
    server.preparePeerVideo(ea, for: a, admission: aa)
    server.commitPeerVideo(ea, catalog: catalog(ea), admission: aa, to: a, requestKeyframe: {})
    server.resetPeerVideo(for: a, expectedEpoch: ea.id)
    server.sendPeerVideo(msg(.frame), epoch: ea.id, to: a)
    server.commitPeerVideo(newer, catalog: catalog(newer), admission: fresh, to: a, requestKeyframe: {})
    server.sendPeerVideo(msg(.parameterSets, sets), epoch: newer.id, to: a)
    server.sendPeerVideo(msg(.frame), epoch: newer.id, to: a)
    server.flush()
    check(a.sent.compactMap(StreamMessage.parseHeader).last?.kind == .epochFrame, "stale prepare/commit/reset cannot stop newer epoch")
    let beforeSlow = a.sent.count
    server.queue.sync { let c = server.clients[ObjectIdentifier(b)]!; c.awaitingFirstKeyframe = false; c.needsKeyframe = false; c.pendingBytes = StreamServer.remoteHoldCap * 3; c.backlogFloor = 0 }
    server.sendPeerVideo(msg(.frame, key: false), epoch: eb.id, to: b)
    server.flush()
    check(b.sent.count == bc, "slow B delta dropped")
    server.sendPeerVideo(msg(.frame), epoch: newer.id, to: a)
    server.flush()
    check(a.sent.count == beforeSlow + 1, "slow B does not reset A")
    var asked: [ObjectIdentifier] = []
    server.onPeerKeyframeNeeded = { asked.append(ObjectIdentifier($0)) }
    server.queue.sync { let c = server.clients[ObjectIdentifier(b)]!; c.pendingBytes = 0; c.keyframesInFlight = []; c.keyframeBytesInFlight = 0; server.sweep() }
    check(asked == [ObjectIdentifier(b)], "sweep asks only B encoder")
    server.queue.sync { server.replayCatalog(to: server.clients[ObjectIdentifier(b)]!) }
    let replay = b.sent.last.flatMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(replay?.videoEpoch == eb, "catalog replay retains B admission")
    let fingerprint = Data([7])
    server.queue.sync { let c = server.clients[ObjectIdentifier(b)]!; c.route.encrypted = true; c.route.fingerprint = fingerprint }
    let grant = HostLocalOwnerGrant(epoch: eb.id, fingerprint: fingerprint)
    var micList = WindowList(macName: "fixture", windows: [], active: eb.source, inputGeneration: eb.generation, videoEpoch: eb)
    micList.microphone = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())
    server.sendMicrophoneCatalog(msg(.windowList, Wire.encode(micList)), to: b, grant: grant, admission: ab)
    server.flush()
    check(server.queue.sync { server.clients[ObjectIdentifier(b)]!.microphoneCatalogGrant === grant }, "microphone catalog uses B epoch despite global admission")
    grant.valid = false
    server.queue.sync { server.replayCatalog(to: server.clients[ObjectIdentifier(b)]!) }
    let revokedReplay = b.sent.last.flatMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(revokedReplay?.microphone == nil && revokedReplay?.videoEpoch == eb, "revoked microphone capability stripped without changing B epoch")
    let watch = PointerWatch(); server.pointerWatch = watch
    server.setPeerPointerRect(CGRect(x: 100, y: 0, width: 100, height: 100), for: a)
    server.setPeerPointerRect(CGRect(x: 700, y: 0, width: 100, height: 100), for: b)
    server.flush()
    server.queue.sync { _ = server.samplePointer(now: 1) }
    let pa = a.sent.last.flatMap { Wire.decode(MacPointer.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    let pb = b.sent.last.flatMap { Wire.decode(MacPointer.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(pa?.x == 0.1 && pb?.x == 0.7 && watch.globalCalls == 0, "peer pointers use own rect without global geometry")
    let pointerCount = a.sent.count
    server.queue.sync { _ = server.samplePointer(now: 2) }
    check(a.sent.count == pointerCount, "pointer dedup is per client")
    let inflight = server.queue.sync { server.clients[ObjectIdentifier(a)]!.inflight }
    server.resetPeerVideo(for: a, expectedEpoch: newer.id)
    server.flush()
    check(server.queue.sync { server.clients[ObjectIdentifier(a)]!.inflight } == inflight, "epoch reset preserves actual outstanding I/O")
    let rectCount = watch.rects.count
    server.queue.sync { _ = server.samplePointer(now: 3) }
    let hidden = a.sent.last.flatMap { Wire.decode(MacPointer.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
    check(hidden?.inside == false && watch.rects.count == rectCount + 1, "stopped peer hides pointer without sampling its old rect")
    server.flush()
    let stoppedCount = a.sent.count
    server.sendPeerVideo(msg(.frame), epoch: newer.id, to: a); server.flush()
    check(a.sent.count == stoppedCount, "reset fences delayed encoder callback")
    let legacyAdmission = SourcePublicationAdmission(), el = epoch(4)
    server.sendCatalog(catalog(nil), to: legacy, admission: legacyAdmission)
    server.flush()
    let legacyDenied = await server.enablePeerVideo(for: legacy)
    check(!legacyDenied, "legacy lane cannot silently change ownership")
    server.prepareVideo(el); server.commitVideo(el, catalog: catalog(el), admission: legacyAdmission, requestKeyframe: {})
    server.broadcast(msg(.parameterSets, sets), epoch: el.id); server.broadcast(msg(.frame), epoch: el.id); server.flush()
    check(legacy.sent.compactMap(StreamMessage.parseHeader).last?.kind == .frame, "legacy untagged adaptation preserved")
    server.queue.sync { _ = server.samplePointer(now: 4) }
    check(watch.globalCalls == 1, "legacy pointer keeps original global sampling")
    ab.invalidate()
    let revokedCount = b.sent.count
    server.sendPeerVideo(msg(.frame), epoch: eb.id, to: b)
    server.queue.sync { server.replayCatalog(to: server.clients[ObjectIdentifier(b)]!) }
    server.flush()
    check(b.sent.count == revokedCount, "invalidated source blocks media and queued catalog replay")
    // Retain and complete real production accounting across a reset.
    server.queue.sync { a.drain() }
    check(server.queue.sync { server.clients[ObjectIdentifier(a)]!.inflight } == 0, "outstanding completion accounting drains after reset")
}
let done = DispatchSemaphore(value: 0)
Task { await runPeers(); done.signal() }
done.wait()
#else
let ea = epoch(1), eb = epoch(2)
let aa = SourcePublicationAdmission(), ab = SourcePublicationAdmission()
server.sendCatalog(catalog(ea), to: a, admission: aa)
server.sendCatalog(catalog(eb), to: b, admission: ab)
server.prepareVideo(ea)
server.commitVideo(ea, catalog: catalog(ea), admission: aa, requestKeyframe: {})
server.flush()
let overwritten = b.sent.last.flatMap { Wire.decode(WindowList.self, from: Data($0.dropFirst(StreamMessage.headerLength))) }
check(overwritten?.videoEpoch == eb, "baseline B catalog stays independent of A commit")
server.queue.sync { server.clients[ObjectIdentifier(a)]!.needsKeyframe = false }
server.prepareVideo(eb); server.flush()
check(server.queue.sync { !server.clients[ObjectIdentifier(a)]!.needsKeyframe }, "baseline B prepare does not reset A")
server.commitVideo(eb, catalog: catalog(eb), admission: ab, requestKeyframe: {})
server.resetForNewStream(); server.flush()
check(server.queue.sync { server.videoAdmission.admits(eb.id) }, "baseline unscoped reset does not stop newer B")
#endif
print("peer-video-transport assertions=\(assertions) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
