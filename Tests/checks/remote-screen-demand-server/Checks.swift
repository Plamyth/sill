var count = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    count += 1
}
func epoch(_ id: UInt32) -> VideoEpoch {
    .init(generation: UUID().uuidString, source: .window(id),
          geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
}
func catalog(_ epoch: VideoEpoch?) -> StreamMessage {
    var list = WindowList(macName: "격리", windows: [], active: epoch?.source ?? .none)
    list.videoEpoch = epoch
    list.inputGeneration = epoch?.generation
    return .init(kind: .windowList, timestamp: 0, isKeyframe: false, payload: Wire.encode(list))
}
let identity = RemoteScreenDemandObservation.Source.window(.init(windowID: 1, ownerPID: 2,
    ownerStartSeconds: 3, ownerStartMicroseconds: 4, bundleIdentifier: "md.obsidian"))
let server = StreamServer()
let trust = TrustBox()
server.screenDemandTrust = trust
var observations: [RemoteScreenDemandObservation] = []
server.onScreenDemand = { observations.append($0) }
let a = NWConnection(), b = NWConnection(), audio = NWConnection()
server.add(a); server.add(b); server.add(audio)
server.queue.sync {
    server.clients[ObjectIdentifier(audio)]!.role = .controlOnly
    server.publishScreenDemand()
}
check(observations.last!.complete && observations.last!.consumers.isEmpty, "audio-only and unassigned viewers do not create demand")
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    let enabledA = await server.enablePeerVideo(for: a)
    let enabledB = await server.enablePeerVideo(for: b)
    check(enabledA && enabledB, "independent lanes enabled")
    semaphore.signal()
}
semaphore.wait()
let first = epoch(1), second = epoch(2)
let secondIdentity = RemoteScreenDemandObservation.Source.window(.init(windowID: 2, ownerPID: 2,
    ownerStartSeconds: 3, ownerStartMicroseconds: 4, bundleIdentifier: "md.obsidian"))
let publication = SourcePublicationAdmission()
server.preparePeerVideo(first, for: a, admission: publication)
server.flush()
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "preparing is unknown")
server.commitPeerVideo(first, catalog: catalog(first), admission: publication,
    screenDemandIdentity: identity, to: a, requestKeyframe: {})
server.flush()
check(observations.last!.complete && observations.last!.consumers.count == 1, "committed paired viewer creates demand")
let wire = try observations.last!.request(now: observations.last!.observedAt)
print("WIRE_FIXTURE=" + String(data: try JSONEncoder().encode(wire), encoding: .utf8)!)
server.queue.sync {
    server.clients[ObjectIdentifier(a)]!.screenDemandIdentity = secondIdentity
    server.publishScreenDemand()
}
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "current identity from another window cannot attach to epoch")
server.queue.sync {
    server.clients[ObjectIdentifier(a)]!.screenDemandIdentity = identity
    server.publishScreenDemand()
}
let incarnation = observations.last!.consumers[0].incarnation
let originalDeadline = observations.last!.consumers[0].expiresAt
server.queue.sync {
    let client = server.clients[ObjectIdentifier(b)]!
    server.publishScreenDemand(renewing: client)
}
check(observations.last!.consumers[0].expiresAt == originalDeadline, "another peer statistics cannot renew A")
server.queue.sync {
    server.clients[ObjectIdentifier(a)]!.screenDemandExpiresAt = ProcessInfo.processInfo.systemUptime - 1
    server.publishScreenDemand(renewing: server.clients[ObjectIdentifier(b)]!)
}
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "expired A remains unknown despite B activity")
server.queue.sync { server.publishScreenDemand(renewing: server.clients[ObjectIdentifier(a)]!) }
check(observations.last!.consumers.first?.incarnation == incarnation, "same live epoch can renew own observation")
RemoteScreenDemandIdentity.current = false
server.queue.sync { server.publishScreenDemand(renewing: server.clients[ObjectIdentifier(a)]!) }
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "reused window PID birth or display UUID cannot keep old scope")
RemoteScreenDemandIdentity.current = true
publication.invalidate()
server.queue.sync { server.publishScreenDemand(renewing: server.clients[ObjectIdentifier(a)]!) }
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "invalidated publication cannot create positive demand")
let fresh = SourcePublicationAdmission()
server.preparePeerVideo(second, for: a, admission: fresh)
server.commitPeerVideo(first, catalog: catalog(first), admission: publication,
    screenDemandIdentity: identity, to: a, requestKeyframe: {})
server.flush()
check(!observations.last!.complete && observations.last!.consumers.isEmpty, "late old commit cannot overwrite new preparing epoch")
server.commitPeerVideo(second, catalog: catalog(second), admission: fresh,
    screenDemandIdentity: secondIdentity, to: a, requestKeyframe: {})
server.flush()
check(observations.last!.consumers.first?.epoch.id == second.id, "new epoch replaces observation atomically")
server.resetPeerVideo(for: a, expectedEpoch: first.id)
server.flush()
check(observations.last!.consumers.first?.epoch.id == second.id, "late reset cannot remove new epoch")
trust.trusted = false
server.screenDemandTrustChanged(); server.flush()
check(observations.last!.complete && observations.last!.consumers.isEmpty, "trust revocation removes screen consumer")
trust.trusted = true
server.queue.sync {
    server.clients[ObjectIdentifier(a)]!.role = .awaitingHello
    server.publishScreenDemand()
}
check(observations.last!.complete && observations.last!.consumers.isEmpty, "awaiting hello never grants demand")
server.queue.sync {
    server.clients[ObjectIdentifier(a)]!.role = .viewer
    a.state = .cancelled
    server.publishScreenDemand()
}
check(observations.last!.complete && observations.last!.consumers.isEmpty, "disconnected peer cannot remain active")
let legacy = NWConnection()
server.add(legacy)
server.queue.sync {
    let client = server.clients[ObjectIdentifier(legacy)]!
    client.videoLane = .legacy
    client.catalogSent = true
}
let legacyEpoch = epoch(3)
server.prepareVideo(legacyEpoch)
server.commitVideo(legacyEpoch, catalog: catalog(legacyEpoch), admission: SourcePublicationAdmission(),
    screenDemandIdentity: .window(.init(windowID: 3, ownerPID: 2, ownerStartSeconds: 3,
        ownerStartMicroseconds: 4, bundleIdentifier: "md.obsidian")), requestKeyframe: {})
server.flush()
check(observations.last!.consumers.count == 1, "legacy requires committed catalog and its live connection")
server.queue.sync {
    server.clients.removeValue(forKey: ObjectIdentifier(legacy))
    server.publishScreenDemand()
}
check(observations.last!.complete && observations.last!.consumers.isEmpty, "remaining global epoch alone creates no demand")
check(zip(observations, observations.dropFirst()).allSatisfy { pair in pair.0.revision < pair.1.revision }, "aggregation revisions strictly increase")
print("PASS \(count) production screen-demand checks")
