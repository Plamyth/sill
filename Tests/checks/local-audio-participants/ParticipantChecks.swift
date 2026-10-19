import Foundation
import StreamProtocol

@MainActor
private final class ParticipantProbe {
    var calls = 0
    var receipt: LocalAudioParticipantReceipt?
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    var mutate: (() -> Void)?
    var facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)
    var control: LocalAudioParticipantRegistry.Control {
        .init(fenceAndQuiesce: { request in
            self.calls += 1
            if self.hold { await withCheckedContinuation { self.held = $0 } }
            let value = LocalAudioParticipantReceipt(request, state: .quiescent, facts: self.facts)
            self.receipt = value
            return value
        }, inspect: { _ in
            self.mutate?()
            guard let old = self.receipt else { return nil }
            return LocalAudioParticipantReceipt(LocalAudioParticipantRequest(schemaVersion: old.schemaVersion,
                operationId: old.operationId, privacyGeneration: old.privacyGeneration, registryRevision: old.registryRevision,
                participantId: old.participantId, bootId: old.bootId, budgetMilliseconds: 100), state: .quiescent, facts: self.facts)
        })
    }
}

@MainActor
private final class ParticipantHALProbe: HostAudioPrivacyHAL {
    private let hal: CoreAudioPrivacyHAL
    private(set) var restores = 0
    init(_ fake: PrivacyFakeHAL) { hal = CoreAudioPrivacyHAL(ops: fake.operations) }
    func read() throws -> PrivacyAudioSnapshot { try hal.read() }
    func write(_ change: PrivacyAudioWrite) -> Bool { hal.write(change) }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        hal.observe(snapshot, changed: changed)
    }
    func restoreLocal(_ state: LocalAudioState) -> Bool {
        restores += 1
        return hal.restoreLocal(state)
    }
}

@MainActor
func participantInterop() throws -> Bool {
    let args = CommandLine.arguments
    if args.count >= 3, args[1] == "--emit-request" {
        let boot: UUID
        if args.count >= 4 {
            guard let parsed = UUID(uuidString: args[3]) else { throw NSError(domain: "InvalidParticipantBoot", code: 1) }
            boot = parsed
        } else { boot = UUID() }
        let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(), privacyGeneration: UUID(),
            registryRevision: "2", participantId: .relay, bootId: boot, budgetMilliseconds: 1000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(request)
        if args[2] == "-" { FileHandle.standardOutput.write(data) }
        else { try data.write(to: URL(fileURLWithPath: args[2])) }
        return true
    }
    if args.count == 4, args[1] == "--read-receipt" {
        let request = try JSONDecoder().decode(LocalAudioParticipantRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let receipt = try JSONDecoder().decode(LocalAudioParticipantReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        guard request.isValid, receipt.proves(request) else { throw NSError(domain: "ParticipantReceiptRejected", code: 1) }
        print("PARTICIPANT_RECEIPT_VALID")
        return true
    }
    return false
}

@MainActor
func participantChecks() async {
    let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)
    let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(), privacyGeneration: UUID(),
        registryRevision: "2", participantId: .relay, bootId: UUID(), budgetMilliseconds: 100)
    let json = try! JSONEncoder().encode(request)
    let decoded = try! JSONDecoder().decode(LocalAudioParticipantRequest.self, from: json)
    expect(decoded == request && decoded.isValid, "actual Codable request round trip")
    let lower = String(data: json, encoding: .utf8)!.lowercased().replacingOccurrences(of: "schemaversion", with: "schemaVersion")
        .replacingOccurrences(of: "operationid", with: "operationId").replacingOccurrences(of: "privacygeneration", with: "privacyGeneration")
        .replacingOccurrences(of: "registryrevision", with: "registryRevision").replacingOccurrences(of: "participantid", with: "participantId")
        .replacingOccurrences(of: "bootid", with: "bootId").replacingOccurrences(of: "budgetmilliseconds", with: "budgetMilliseconds")
    expect(try! JSONDecoder().decode(LocalAudioParticipantRequest.self, from: Data(lower.utf8)) == request, "UUID arguments normalize before equality")
    let receipt = LocalAudioParticipantReceipt(request, state: .quiescent, facts: facts)
    expect(try! JSONDecoder().decode(LocalAudioParticipantReceipt.self, from: JSONEncoder().encode(receipt)).proves(request), "actual receipt decoder and validator")
    for field in ["operationId", "privacyGeneration", "bootId", "registryRevision", "participantId", "schemaVersion"] {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        if field == "registryRevision" { object[field] = "3" }
        else if field == "schemaVersion" { object[field] = 2 }
        else if field == "participantId" { object[field] = "native.sill" }
        else { object[field] = UUID().uuidString }
        let wrong = try! JSONDecoder().decode(LocalAudioParticipantReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        expect(!wrong.proves(request), "wrong or replayed receipt identity refuses \(field)")
    }
    var unknown = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
    unknown["participantId"] = "unregistered.owner"
    expect((try? JSONDecoder().decode(LocalAudioParticipantRequest.self, from: JSONSerialization.data(withJSONObject: unknown))) == nil,
        "unknown serialized participant ID is not constructor authority")
    for replacement in ["null", "false"] {
        let data = try! JSONEncoder().encode(receipt)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var f = object["facts"] as! [String: Any]
        if replacement == "null" { f["workersExited"] = NSNull() } else { f["workersExited"] = false }
        object["facts"] = f
        let invalid = try! JSONDecoder().decode(LocalAudioParticipantReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        expect(!invalid.proves(request), "null or false never proves worker exit \(replacement)")
    }
    for extra in [false, true] {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        var f = object["facts"] as! [String: Any]
        if extra { f["invented"] = true } else { f.removeValue(forKey: "buffersEmpty") }
        object["facts"] = f
        expect((try? JSONDecoder().decode(LocalAudioParticipantReceipt.self, from: JSONSerialization.data(withJSONObject: object))) == nil,
            "facts require exactly the frozen six fields \(extra)")
    }
    for budget in [0, 30_001] {
        let bad = LocalAudioParticipantRequest(schemaVersion: 1, operationId: request.operationId, privacyGeneration: request.privacyGeneration,
            registryRevision: "02", participantId: .relay, bootId: request.bootId, budgetMilliseconds: budget)
        expect(!bad.isValid, "noncanonical revision or invalid budget refuses \(budget)")
    }
    for fault in [0, 1, 2, 3] {
        let registry = LocalAudioParticipantRegistry(), native = ParticipantProbe(), relay = ParticipantProbe()
        registry.register(.native, bootId: UUID(), control: native.control)
        registry.register(.relay, bootId: UUID(), control: relay.control)
        let membership = registry.snapshot, op = UUID(), generation = UUID()
        let ready = await registry.fenceAndQuiesce(operationId: op, privacyGeneration: generation, membership: membership, budgetMilliseconds: 1000)
        expect(ready && registry.isFenced, "registry quiesces required members \(fault)")
        let duplicate = await registry.fenceAndQuiesce(operationId: op, privacyGeneration: generation, membership: membership, budgetMilliseconds: 1000)
        expect(duplicate && native.calls == 1 && relay.calls == 1, "same operation never quiesces twice \(fault)")
        let conflict = await registry.fenceAndQuiesce(operationId: UUID(), privacyGeneration: generation, membership: membership, budgetMilliseconds: 1000)
        expect(!conflict && relay.calls == 1, "conflicting operation cannot create workers \(fault)")
        if fault == 0 { registry.register(.relay, bootId: UUID(), control: relay.control) }
        if fault == 1 { registry.unregister(.relay) }
        if fault == 2 { relay.facts = .unknown }
        if fault == 3 { relay.mutate = { registry.register(.native, bootId: UUID(), control: native.control) } }
        let inspected = await registry.inspectAll(operationId: op, privacyGeneration: generation, membership: membership)
        expect(!inspected && !registry.proofCurrent(operationId: op, privacyGeneration: generation, membership: membership),
            "restart missing unknown or mid-inspection membership invalidates proof \(fault)")
    }
    let registry = LocalAudioParticipantRegistry(), native = ParticipantProbe(), stalled = ParticipantProbe()
    registry.register(.native, bootId: UUID(), control: native.control)
    stalled.hold = true
    registry.register(.relay, bootId: UUID(), control: stalled.control)
    let membership = registry.snapshot, op = UUID(), generation = UUID(), start = ContinuousClock.now
    let timed = await registry.fenceAndQuiesce(operationId: op, privacyGeneration: generation, membership: membership, budgetMilliseconds: 20)
    expect(!timed && start.duration(to: ContinuousClock.now) < .seconds(1) && registry.isFenced && stalled.held != nil,
           "noncooperative participant deadline returns with fence retained before worker release")
    stalled.held?.resume(); stalled.held = nil
    for _ in 0..<20 { await Task.yield() }
    let retry = await registry.fenceAndQuiesce(operationId: op, privacyGeneration: generation, membership: membership, budgetMilliseconds: 20)
    let late = await registry.inspectAll(operationId: op, privacyGeneration: generation, membership: membership)
    expect(!retry && !late && stalled.calls == 1, "late worker cannot bless stale token or create a second quiesce")
    await cancellationParticipantChecks()
    await inspectionDeadlineParticipantChecks()
    await lateCaptureParticipantChecks()
    await lifecycleParticipantChecks()
    await missingRelayDuringStartupChecks()
    await pendingAuthenticationChecks()
    await delayedMicrophoneRetirementChecks()
}

@MainActor
private func missingRelayDuringStartupChecks() async {
    let fake = PrivacyFakeHAL(), startup = NativeAudioStartup()
    let hal = ParticipantHALProbe(fake)
    var authCalls = 0
    let privacy = fixturePrivacy(hal: hal, clearLatch: { true },
        authenticateLocal: { _ in authCalls += 1; return true }, nativeStartup: startup)
    expect(privacy.armAndVerify(), "missing startup relay fixture armed")
    let coordinator = PrivacyCoordinatorFixture(privacy)
    let peer = BoundaryConnection(), id = ObjectIdentifier(peer), server = coordinator.server
    coordinator.connections[id] = peer
    coordinator.remoteAudioSubscribers.insert(id)
    coordinator.remoteAudioRunning = true
    server.queue.sync { server.clients[id] = BoundaryServer.Client(peer) }
    server.setRemoteAudio(true, for: peer, afterSequence: 0)
    server.broadcastRemoteAudio(Data([1]), epoch: 0, sequence: 1)
    expect(server.queue.sync { peer.completions.count } == 1, "startup relay fixture has pending remote audio")
    let snapshot = fake.snapshot, writes = fake.writes
    var entered = false, completed = false
    let task = Task { @MainActor in
        entered = true
        let result = await privacy.requestLocalReturn()
        completed = true
        return result
    }
    while !entered { await Task.yield() }
    expect(!completed && authCalls == 0 && hal.restores == 0 && privacy.localReturnUnavailableReason == nil,
           "local return waits for startup with relay available and no auth or restore")
    privacy.participants.unregister(.relay)
    startup.construct { coordinator }
    let result = await task.value
    expect(!result && authCalls == 0 && hal.restores == 0 && privacy.latched && privacy.verify() &&
           !privacy.participants.isFenced && fake.snapshot == snapshot && fake.writes == writes,
           "missing relay during startup refuses with auth invocations 0 and HAL restores 0")
    server.broadcastRemoteAudio(Data([2]), epoch: 0, sequence: 2)
    expect(coordinator.remoteAudioRunning && coordinator.remoteAudioSubscribers == [id] &&
           coordinator.remoteAudioCapture.stops == 0 && coordinator.microphoneIngress.revoked == 0 &&
           coordinator.microphoneReceiver.revoked == 0 && !coordinator.physicalAudioRoutesRetired &&
           server.queue.sync { peer.completions.count == 2 && server.clients[id]?.remoteAudioEnabled == true && server.remoteAudioEpoch == 0 },
           "missing relay during startup leaves remote audio unchanged and still delivering")
    server.queue.sync {
        let callbacks = peer.completions; peer.completions.removeAll()
        callbacks.forEach { $0() }
    }
    privacy.stop()
}

@MainActor
private func pendingAuthenticationChecks() async {
    let fake = PrivacyFakeHAL()
    var reply: CheckedContinuation<Bool, Never>?
    var calls = 0
    let privacy = fixturePrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), clearLatch: { true },
        authenticateLocal: { _ in await withCheckedContinuation { reply = $0 } })
    privacy.revokeForLocalReturn = { calls += 1; return true }
    expect(privacy.armAndVerify(), "pending auth actual host armed")
    let task = Task { await privacy.requestLocalReturn() }
    for _ in 0..<50 { if reply != nil { break }; await Task.yield() }
    expect(reply != nil && privacy.verify() && privacy.reconcile() && !privacy.participants.isFenced && calls == 0,
           "pending OS auth preserves actual verify reconcile and remote audio")
    let writes = fake.writes.count
    task.cancel(); reply?.resume(returning: true); reply = nil
    let result = await task.value
    expect(!result && calls == 0 && privacy.verify() && fake.writes.count == writes && !privacy.participants.isFenced,
           "pre-fence cancellation performs no quiesce restore or implicit audio revoke")
    privacy.stop()
}

@MainActor
private final class DelayedParticipantSink: HostMicrophoneSink {
    var closeReply: CheckedContinuation<String?, Never>?
    func close() async -> String? { await withCheckedContinuation { closeReply = $0 } }
    func runtimeValid() -> Bool { true }
}
@MainActor
private final class ParticipantMicrophoneOwner: HostMicrophoneOriginalOwner {
    let grant: HostLocalOwnerGrant
    init(_ grant: HostLocalOwnerGrant) { self.grant = grant }
    func microphoneGrant(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID, fingerprint: Data) -> HostLocalOwnerGrant? { grant }
}
@MainActor
private func delayedMicrophoneRetirementChecks() async {
    let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), destination: UUID(), capability: UUID())
    let grant = HostLocalOwnerGrant(owner: UUID(), callGeneration: UUID(), scope: scope, fingerprint: Data([1]),
        destination: HostMicrophoneDestination(outputUID: "fake.output", inputUID: "fake.input", pluginBundleID: "fake.plugin",
            outputChannels: 2, inputChannels: 2, outputChannel: 1, inputChannel: 0)!,
        expiresAt: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
    let sink = DelayedParticipantSink()
    let receiver = HostMicrophoneReceiver(provider: ParticipantMicrophoneOwner(grant), automaticWatchdog: false,
        prepare: { _, _ in HostMicrophonePreparation(resource: sink, error: nil) })
    receiver.current = { _, _ in true }
    _ = receiver.capability(peer: scope.peer, source: scope.source, inputGeneration: scope.inputGeneration,
        videoEpoch: scope.videoEpoch, fingerprint: Data([1]))
    receiver.control(MicrophoneControl(operation: .start, requestID: UUID(), scope: scope), fingerprint: Data([1]))
    for _ in 0..<30 { await Task.yield() }
    expect(receiver.phase == .active, "actual receiver acquires injected delayed sink")
    let fake = PrivacyFakeHAL()
    let privacy = fixturePrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), clearLatch: { true }, authenticateLocal: { _ in true })
    let coordinator = PrivacyCoordinatorFixture(privacy)
    coordinator.microphoneReceiver.actual = receiver
    expect(privacy.armAndVerify(), "actual restore caller delayed sink armed")
    let writes = fake.writes.count
    let returned = await privacy.requestLocalReturn(budgetMilliseconds: 20)
    expect(!returned && privacy.latched && privacy.participants.isFenced && fake.writes.count == writes && !receiver.retirementComplete,
        "actual extracted prepare and registry caller refuse restore while sink close is delayed")
    let result = await LocalAudioCompletion<Bool>.wait(until: ContinuousClock.now.advanced(by: .milliseconds(20))) { await receiver.waitForRetirement() }
    expect(result != true && !receiver.retirementComplete && sink.closeReply != nil,
           "closed render gate cannot prove actual delayed sink retirement")
    sink.closeReply?.resume(returning: nil); sink.closeReply = nil
    let closed = await LocalAudioCompletion<Bool>.wait(until: ContinuousClock.now.advanced(by: .seconds(1))) { await receiver.waitForRetirement() }
    expect(closed == true && receiver.retirementComplete, "actual close completion releases retirement waiter")
    let lateReturn = await privacy.requestLocalReturn(budgetMilliseconds: 20)
    expect(!lateReturn && fake.writes.count == writes && privacy.participants.isFenced,
        "late actual sink close never restores or implicitly unfences")
    privacy.stop()
}

@MainActor
private func lifecycleParticipantChecks() async {
    let lifecycle = RemoteAudioCaptureLifecycle()
    var completion: CheckedContinuation<Bool, Never>?
    var stopped = false
    let old = lifecycle.acquireStart { await withCheckedContinuation { completion = $0 } }
    for _ in 0..<20 { if completion != nil { break }; await Task.yield() }
    lifecycle.scheduleStop { stopped = true }
    completion?.resume(returning: true); completion = nil
    await lifecycle.waitUntilIdle()
    expect(stopped && lifecycle.isIdle, "stop settles captured start without needing original settle waiter")
    let replacement = lifecycle.acquireStart { true }
    _ = await lifecycle.settleStart(old)
    expect(!lifecycle.isIdle, "late original settle cannot clear replacement start identity")
    _ = await lifecycle.settleStart(replacement)
    expect(lifecycle.isIdle, "replacement start settles only its own lifecycle record")
}

@MainActor
private func lateCaptureParticipantChecks() async {
    let fake = PrivacyFakeHAL()
    let privacy = fixturePrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), clearLatch: { true }, authenticateLocal: { _ in true })
    let coordinator = PrivacyCoordinatorFixture(privacy)
    let peer = BoundaryConnection()
    let server = coordinator.server
    var captured: CheckedContinuation<Void, Never>?
    coordinator.remoteAudioCapture.onStop = {
        coordinator.remoteAudioCapture.onStop = nil
        await withCheckedContinuation { captured = $0 }
        server.queue.async {
            server.broadcastRemoteAudio(Data([7]), epoch: 0, sequence: 99)
            server.remoteAudioDrain.enter()
            peer.completions.append { server.remoteAudioDrain.leave() }
        }
    }
    expect(privacy.armAndVerify(), "late capture callback actual host armed")
    let writes = fake.writes.count
    let task = Task { await privacy.requestLocalReturn(budgetMilliseconds: 1000) }
    for _ in 0..<80 { if captured != nil { break }; await Task.yield() }
    expect(captured != nil && fake.writes.count == writes, "producer stop is held after initial server drain")
    captured?.resume(); captured = nil
    for _ in 0..<80 {
        if server.queue.sync(execute: { !peer.completions.isEmpty }) { break }
        await Task.yield()
    }
    expect(server.queue.sync { peer.completions.count } == 1 && fake.writes.count == writes,
           "final actual server barrier waits for late queued capture completion")
    server.queue.sync {
        let pending = peer.completions; peer.completions.removeAll()
        pending.forEach { $0() }
    }
    let result = await task.value
    if !result {
        print("Late capture return rejected: stops=\(coordinator.remoteAudioCapture.stops) held=\(captured != nil) drained=\(coordinator.localAudioReturnDrained) facts=\(String(describing: privacy.inspectForLocalReturn?())) reason=\(privacy.state.reason ?? "none")")
    }
    expect(result && !privacy.latched, "restore consumes final drain after producer and sink retirement")
    privacy.stop()
}

@MainActor
private func cancellationParticipantChecks() async {
    let registry = LocalAudioParticipantRegistry(), native = ParticipantProbe(), relay = ParticipantProbe()
    native.hold = true
    registry.register(.native, bootId: UUID(), control: native.control)
    registry.register(.relay, bootId: UUID(), control: relay.control)
    let snapshot = registry.snapshot, id = UUID(), generation = UUID()
    let task = Task { await registry.fenceAndQuiesce(operationId: id, privacyGeneration: generation,
        membership: snapshot, budgetMilliseconds: 1000) }
    for _ in 0..<60 { if native.held != nil { break }; await Task.yield() }
    expect(registry.isFenced && native.held != nil, "global authority fence precedes first participant suspension")
    task.cancel()
    let result = await task.value
    expect(!result && registry.isFenced, "post-fence cancellation returns without implicit unfence")
    native.held?.resume(); native.held = nil
    for _ in 0..<30 { await Task.yield() }
    expect(native.calls == 1 && relay.calls == 0 && !registry.proofCurrent(operationId: id, privacyGeneration: generation, membership: snapshot),
        "cancelled late participant cannot dispatch next member or authorize restore")
}

@MainActor
private func inspectionDeadlineParticipantChecks() async {
    let registry = LocalAudioParticipantRegistry(), native = ParticipantProbe(), relay = ParticipantProbe()
    var release: CheckedContinuation<Void, Never>?
    registry.register(.native, bootId: UUID(), control: native.control)
    registry.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: relay.control.fenceAndQuiesce, inspect: { _ in
        await withCheckedContinuation { release = $0 }
        return relay.receipt
    }))
    let snapshot = registry.snapshot, id = UUID(), generation = UUID(), start = ContinuousClock.now
    let ready = await registry.fenceAndQuiesce(operationId: id, privacyGeneration: generation, membership: snapshot, budgetMilliseconds: 30)
    expect(ready, "inspection deadline fixture quiesces")
    let result = await registry.inspectAll(operationId: id, privacyGeneration: generation, membership: snapshot)
    expect(!result && release != nil && start.duration(to: ContinuousClock.now) < .seconds(1) && registry.isFenced,
        "noncooperative fresh inspector is bounded by original operation deadline")
    release?.resume(); release = nil
    for _ in 0..<20 { await Task.yield() }
    expect(!registry.proofCurrent(operationId: id, privacyGeneration: generation, membership: snapshot),
        "late fresh inspector never revives expired proof")
}
