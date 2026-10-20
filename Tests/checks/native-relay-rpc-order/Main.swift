import Foundation

@MainActor final class Fixture {
    let child = Process()
    let registry = LocalAudioParticipantRegistry()
    let log: URL
    let relay: LocalAudioRelay
    static var number = 0

    init(_ mode: String) {
        Self.number += 1
        log = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("child-\(Self.number).jsonl")
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [CommandLine.arguments[1], mode, log.path]
        relay = LocalAudioRelay(participants: registry, process: child,
            packagedRuntime: .init(python: "inert-python", router: "inert-router", port: 0), forwarding: true,
            validateLaunch: { true })
        registry.register(.native, bootId: UUID(), control: .init(fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) },
            inspect: { _ in nil }, supportsForwarding: true, forwardingPrepare: { .init($0.request, state: .quiescent,
                facts: .init(admissionFenced: true, startsSettled: true, mediaDetached: true,
                             callbacksDrained: true, buffersEmpty: true, workersExited: true)) }))
    }
    static func make(_ mode: String = "valid") async -> Fixture {
        let f = Fixture(mode)
        let started = await f.relay.start()
        precondition(started)
        return f
    }
    func finish() {
        relay.lost()
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        precondition(!child.isRunning && relay.checkDrained)
    }
    func requests() -> [[String: Any]] {
        (try! String(contentsOf: log, encoding: .utf8)).split(separator: "\n").map {
            try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func binding() async -> AudioForwardingBinding {
        guard case .accepted = await relay.forwardingConfigure(privacyGeneration: UUID()),
              case .accepted(let snapshot) = await relay.forwardingSnapshot(), let binding = snapshot.binding else {
            fatalError("binding fixture")
        }
        return binding
    }
}

@main struct Checks {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ value: Bool, _ message: String) {
        assertions += 1
        precondition(value, message)
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "test barrier expired")
    }
    @MainActor static func main() async {
        if CommandLine.arguments.last == "registered" {
            await registeredPreparation()
            print("PASS \(assertions) registered forwarding assertions. Actual private pipe, inert child only.")
            return
        }
        if CommandLine.arguments.last == "conflict" {
            await preparationConflict()
            print("PASS \(assertions) conflict receipt assertions. Actual private pipe, inert child only.")
            return
        }
        if CommandLine.arguments.last != "http-admission" {
            await fifo()
            await queuedCancellationAndDeadline()
            await acquiredCancellation()
            await registryCallers()
            await finalAdmission()
            await activeFailure()
            await lostDrain()
            await invalidReplies()
            await sequenceLimit()
            await prepare()
        }
        await httpPreparation()
        await reentrantAdmission()
        await preparationConflict()
        await registeredPreparation()
        print("PASS \(assertions) assertions. Actual LocalAudioRelay private call, inert stdio only.")
    }
    @MainActor static func registeredPreparation() async {
        for cancel in [false, true] {
            let f = await Fixture.make(), binding = await f.binding()
            let membership = f.registry.snapshot
            guard let ticket = f.registry.beginForwarding(epoch: binding.bindingEpoch, intentGeneration: binding.intentGeneration,
                operationId: binding.operationId, privacyGeneration: binding.configuration.privacyGeneration,
                membership: membership, identity: [binding.transportId.uuidString]) else { fatalError("registered forwarding capability missing") }
            let request = binding.participantRequest(for: .relay, budgetMilliseconds: 2000)!
            let hold: Task<Int?, Never>? = cancel ? Task { await f.relay.checkedCall("hold-registered", until: .now.advanced(by: .seconds(2))) } : nil
            if cancel { await wait { f.relay.checkPending } }
            let count = f.requests().filter { $0["method"] as? String == "forwardingPrepare" }.count
            let prepare = Task { await f.registry.prepareForwarding(ticket, request: request, until: .now.advanced(by: .seconds(2))) }
            if cancel {
                await wait { f.relay.checkWaiting == 1 }
                f.registry.cancelForwarding(ticket)
                expect(await hold?.value == 1, "existing private call survives cancelled binding")
            }
            let receipt = await prepare.value
            if cancel {
                expect(receipt == nil && f.relay.checkConnected && f.registry.matches(membership), "cancelled registered preparation preserves connection")
                expect(f.requests().filter { $0["method"] as? String == "forwardingPrepare" }.count == count,
                       "cancelled binding is not submitted after waiting for the slot")
            } else {
                expect(receipt?.proves(request) == true, "actual registered typed callback prepares the relay")
                let nativeRequest = binding.participantRequest(for: .native, budgetMilliseconds: 2000)!
                let nativeReceipt = await f.registry.prepareForwarding(ticket, request: nativeRequest, until: .now.advanced(by: .seconds(1)))
                expect(nativeReceipt?.proves(nativeRequest) == true, "both members are prepared before inspect")
                let inspected = await f.registry.inspectForwarding(ticket, request: request, until: .now.advanced(by: .seconds(1)))
                expect(inspected?.proves(request) == true, "registered inspect confirms the same prepared relay")
                expect(f.relay.checkConnected && f.registry.matches(membership), "registered preparation preserves boot and membership")
            }
            f.finish()
        }
    }
    @MainActor static func preparationConflict() async {
        for field in ["valid", "operationId", "privacyGeneration", "bootId", "registryRevision", "schemaVersion", "participantId", "state", "reason", "facts"] {
            let f = await Fixture.make("conflict-\(field)"), binding = await f.binding()
            let original = binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!
            guard case .accepted(let prepared) = await f.relay.forwardingPrepare(binding) else { fatalError("conflict fixture prepare") }
            let stale = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(),
                privacyGeneration: original.privacyGeneration, registryRevision: original.registryRevision,
                participantId: .relay, bootId: original.bootId, budgetMilliseconds: 5000)
            let membership = f.registry.snapshot
            let refusal = await f.registry.checkedFence(stale)
            if field == "valid" {
                expect(refusal?.state == .blocked && refusal?.reason == "audio_preparation_conflict", "known conflict returns typed refusal")
                expect(f.relay.checkConnected && f.registry.matches(membership), "known conflict preserves connection and membership")
                expect(await f.registry.checkedInspect(binding.operationId) == prepared, "known conflict preserves previously prepared binding")
                expect(await f.relay.checkedCall("after-conflict", until: .now.advanced(by: .seconds(1))) == 1, "same child accepts the next RPC")
            } else {
                expect(f.relay.checkClosed, "invalid conflict receipt closes connection \(field)")
            }
            f.finish()
        }
    }
    @MainActor static func httpPreparation() async {
        for mode in ["valid", "http", "http-receipt-bootId", "http-receipt-registryRevision", "http-receipt-privacyGeneration"] {
            let f = await Fixture.make(mode), binding = await f.binding()
            expect(binding.transportKind == (mode == "valid" ? .native : .http), "fixture transport")
            let expected = binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!
            let membership = f.registry.snapshot
            let result = await f.relay.forwardingPrepare(binding)
            if mode == "valid" || mode == "http" {
                guard case .accepted(let receipt) = result else { fatalError("HTTP and native prepare must accept matching relay receipt") }
                expect(receipt.proves(expected) && f.registry.matches(membership), "prepare proves boot, configuration and membership")
                let inspected = await f.registry.checkedInspect(binding.operationId)
                expect(inspected == receipt && inspected?.proves(expected) == true, "inspect returns the same prepared receipt")
                expect(f.relay.checkConnected, "HTTP preparation preserves connection")
                if mode == "http" {
                    let count = f.requests().count, sequence = f.relay.checkSequence
                    let peer = AudioForwardingPairedDevice(id: binding.pairedDeviceId, pairingGeneration: UUID())
                    let credential = try! JSONDecoder().decode(AudioForwardingCredential.self, from: JSONSerialization.data(withJSONObject: [
                        "pairedDeviceId": binding.pairedDeviceId.hex, "pairingGeneration": peer.pairingGeneration.uuidString,
                        "credential": String(repeating: "a", count: 43)]))
                    let intent = try! JSONDecoder().decode(AudioForwardingIntentRequest.self, from: JSONSerialization.data(withJSONObject: [
                        "schemaVersion": 1, "pairedDeviceId": binding.pairedDeviceId.hex, "intentId": UUID().uuidString,
                        "intentRevision": "1", "action": "request", "inputDesired": true, "outputDesired": true,
                        "expectedRevision": "0", "transportId": binding.transportId.uuidString, "transportKind": "http", "bindingRevision": "1"]))
                    expect(await f.relay.forwardingRequest(intent, peer: peer, credential: credential) == nil, "HTTP intent submission remains prohibited")
                    expect(f.requests().count == count && f.relay.checkSequence == sequence, "HTTP intent request is not sent")
                }
            } else {
                expect(result == nil && f.relay.checkClosed, "HTTP preparation rejects mismatched receipt identity")
            }
            f.finish()
        }
    }
    @MainActor static func reentrantAdmission() async {
        for mutation in ["lost", "boot", "phase", "slot", "process"] {
            let f = await Fixture.make(), relay = f.relay
            let sequence = relay.checkSequence, count = f.requests().count
            var completed = false
            let request = Task {
                let result = await relay.checkedCall("reentrant-\(mutation)", until: .now.advanced(by: .seconds(1)), admission: {
                    switch mutation {
                    case "lost": relay.lost()
                    case "boot": relay.checkReplaceConnectedBoot()
                    case "phase": relay.checkReplacePhase()
                    case "slot": relay.checkReplaceSlot()
                    default:
                        f.child.terminate()
                        f.child.waitUntilExit()
                    }
                    return true
                })
                completed = true
                return result
            }
            await wait { completed }
            expect(await request.value == nil, "reentrant admission rejects before send \(mutation)")
            expect(relay.checkSequence == sequence && !relay.checkPending, "reentry consumes no sequence or pending continuation \(mutation)")
            expect(f.requests().count == count, "child receives no reentrant frame \(mutation)")
            f.finish()
        }
    }
    @MainActor static func fifo() async {
        let f = await Fixture.make(), relay = f.relay
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkPending }
        var queued: [Task<Int?, Never>] = []
        for i in 0..<12 {
            queued.append(Task { await relay.checkedCall("fifo-\(i)", until: .now.advanced(by: .seconds(3))) })
            await wait { relay.checkWaiting == i + 1 }
        }
        expect(await first.value == 1, "original overlapped call survives")
        for task in queued { expect(await task.value == 1, "queued call succeeds") }
        let calls = f.requests()
        expect(calls.map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold"] + (0..<12).map { "fifo-\($0)" }, "FIFO order")
        expect(calls.map { $0["sequence"] as! String } == (1...15).map(String.init), "contiguous sequence")
        expect(Set(calls.map { $0["requestId"] as! String }).count == calls.count, "unique request IDs")
        expect(relay.checkConnected && !relay.checkPending && relay.checkWaiting == 0, "valid overlap stays connected")
        f.finish()
    }
    @MainActor static func queuedCancellationAndDeadline() async {
        let f = await Fixture.make(), relay = f.relay
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkPending }
        let cancelled = Task { await relay.checkedCall("cancelled", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkWaiting == 1 }
        let expired = Task { await relay.checkedCall("expired", until: .now.advanced(by: .milliseconds(40))) }
        await wait { relay.checkWaiting == 2 }
        let survivor = Task { await relay.checkedCall("survivor", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkWaiting == 3 }
        cancelled.cancel()
        expect(await cancelled.value == nil, "cancelled waiter returns nil")
        expect(await expired.value == nil, "expired waiter returns nil")
        expect(relay.checkConnected && relay.checkPending && relay.checkSequence == 3, "waiting failures preserve active request")
        let firstValue = await first.value, survivorValue = await survivor.value
        expect(firstValue == 1 && survivorValue == 1, "active and surviving waiter succeed")
        expect(f.requests().map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold", "survivor"], "no cancelled or expired frames")
        let past = await relay.checkedCall("past", until: .now.advanced(by: .seconds(-1)))
        expect(past == nil && relay.checkConnected && relay.checkSequence == 4, "already expired call is not sent")
        f.finish()
    }
    @MainActor static func acquiredCancellation() async {
        let f = await Fixture.make(), relay = f.relay
        let cancelled = Task { await relay.checkedCall("pre-cancelled", until: .now.advanced(by: .seconds(2))) }
        cancelled.cancel()
        expect(await cancelled.value == nil && relay.checkConnected && relay.checkSequence == 2, "pre-cancelled call is not sent")
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        let next = Task { await relay.checkedCall("cancel-before-grant", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 1 }
        next.cancel()
        expect(await next.value == nil, "cancellation removes waiter once")
        expect(await first.value == 1 && relay.checkConnected, "queued cancellation cannot close active child")
        let follow = await relay.checkedCall("follow", until: .now.advanced(by: .seconds(2)))
        expect(follow == 1 && relay.checkConnected, "late cancellation handler cannot close next call")
        f.finish()
    }
    @MainActor static func registryCallers() async {
        for cancelled in [false, true] {
            let f = await Fixture.make(), relay = f.relay
            let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(), privacyGeneration: UUID(),
                registryRevision: String(f.registry.snapshot.revision), participantId: .relay,
                bootId: f.registry.snapshot.boots[.relay]!, budgetMilliseconds: cancelled ? 2000 : 40)
            let hold = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
            await wait { relay.checkPending }
            let fence = Task { await f.registry.checkedFence(request) }
            await wait { relay.checkWaiting == 1 }
            if cancelled { fence.cancel() }
            let receipt = await fence.value
            expect(receipt?.state == .unknown, "queued registry fence returns unknown")
            expect(relay.checkConnected && relay.checkPending, "unsent registry fence must not close child")
            expect(await hold.value == 1, "registry fence does not close active call")
            expect(!f.requests().contains { $0["method"] as? String == "fenceAndQuiesce" }, "registry waiter not sent")
            let actual = await f.registry.checkedFence(request)
            expect(actual?.proves(request) == true, "registry fence still validates actual receipt")
            expect(await f.registry.checkedInspect(request.operationId) == nil && relay.checkConnected, "inspect uses shared pipe")
            f.finish()
        }
    }
    @MainActor static func finalAdmission() async {
        let f = await Fixture.make(), relay = f.relay
        var scopeIsCurrent = true, validations = 0
        let hold = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        let stale = Task { await relay.checkedCall("stale-commit", until: .now.advanced(by: .seconds(2)), admission: {
            validations += 1
            return scopeIsCurrent
        }) }
        await wait { relay.checkWaiting == 1 }
        expect(validations == 0, "admission waits for private pipe slot")
        scopeIsCurrent = false
        let next = Task { await relay.checkedCall("after-stale", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 2 }
        expect(await hold.value == 1, "in-flight request completes before admission")
        expect(await stale.value == nil, "stale coordinator scope rejects unsent request")
        expect(await next.value == 1, "admission refusal releases next FIFO slot")
        expect(validations == 1 && relay.checkConnected, "admission checked exactly once without closing")
        expect(f.requests().map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold", "after-stale"], "no stale frame or sequence gap")
        scopeIsCurrent = true
        let accepted = await relay.checkedCall("admitted", until: .now.advanced(by: .seconds(2)), admission: {
            validations += 1
            return scopeIsCurrent
        })
        expect(accepted == 1 && validations == 2 && relay.checkSequence == 5, "current proof permits one send")
        let expired = await relay.checkedCall("expired-proof", until: .now.advanced(by: .seconds(-1)), admission: {
            validations += 1
            return scopeIsCurrent
        })
        expect(expired == nil && validations == 2 && relay.checkConnected, "expired request does not validate or send")
        var cancellingProof: Task<Int?, Never>?
        cancellingProof = Task { await relay.checkedCall("cancel-in-proof", until: .now.advanced(by: .seconds(2)), admission: {
            cancellingProof?.cancel()
            return scopeIsCurrent
        }) }
        expect(await cancellingProof!.value == nil, "cancellation inside final proof is unsent")
        expect(relay.checkConnected && relay.checkSequence == 5, "final unsent cancellation preserves sequence and pipe")
        f.finish()
    }
    @MainActor static func activeFailure() async {
        for cancel in [true, false] {
            let f = await Fixture.make(), relay = f.relay
            let active = Task { await relay.checkedCall("hold", until: .now.advanced(by: cancel ? .seconds(2) : .milliseconds(60))) }
            await wait { relay.checkPending }
            let queued = Task { await relay.checkedCall("must-not-send", until: .now.advanced(by: .seconds(2))) }
            await wait { relay.checkWaiting == 1 }
            await wait { f.requests().last?["method"] as? String == "hold" }
            if cancel { active.cancel() }
            let activeValue = await active.value, queuedValue = await queued.value
            expect(activeValue == nil && queuedValue == nil, "sent cancel or timeout drains queue")
            expect(relay.checkClosed && relay.checkDrained, "sent failure is fail-closed")
            expect(f.requests().count == 3, "sent failure never sends queued successor")
            f.finish()
        }
    }
    @MainActor static func lostDrain() async {
        let f = await Fixture.make(), relay = f.relay
        let active = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        var queued: [Task<Int?, Never>] = []
        for i in 0..<8 {
            queued.append(Task { await relay.checkedCall("lost-\(i)", until: .now.advanced(by: .milliseconds(300))) })
            await wait { relay.checkWaiting == i + 1 }
        }
        relay.lost(); relay.lost()
        expect(await active.value == nil, "lost resolves active continuation")
        for task in queued { expect(await task.value == nil, "lost resolves queued continuation once") }
        try? await Task.sleep(for: .milliseconds(350))
        expect(relay.checkDrained && relay.checkClosed, "all waiter timers stay drained")
        expect(f.registry.snapshot.boots[.relay] == nil, "lost unregisters matching boot")
        f.finish()
    }
    @MainActor static func invalidReplies() async {
        for mode in ["schemaVersion", "sequence", "controllerBootId", "relayBootId", "requestId", "processId", "unknown", "duplicate", "bom", "oversize", "double", "invalid", "eof", "blank"] {
            let f = await Fixture.make(mode)
            expect(await f.relay.checkedCall("bad", until: .now.advanced(by: .seconds(2))) == nil, "reject \(mode)")
            expect(f.relay.checkClosed && f.relay.checkDrained, "invalid reply closes and drains \(mode)")
            f.finish()
        }
    }
    @MainActor static func sequenceLimit() async {
        let f = await Fixture.make()
        f.relay.checkSetSequence(UInt64.max)
        expect(await f.relay.checkedCall("overflow", until: .now.advanced(by: .seconds(2))) == nil, "sequence cannot wrap")
        expect(f.relay.checkClosed && f.requests().count == 2, "overflow closes before send")
        f.finish()
    }
    @MainActor static func prepare() async {
        for explicit in [true, false] {
            let f = await Fixture.make("slow-prepare")
            let binding = await f.binding()
            let peer = AudioForwardingPairedDevice(id: binding.pairedDeviceId, pairingGeneration: UUID())
            let registration = Task { await f.relay.forwardingRegister(peer) }
            await wait { f.relay.checkPending }
            let poll = Task { await f.relay.forwardingSnapshot() }
            await wait { f.relay.checkWaiting == 1 }
            let prepared = Task { explicit
                ? await f.relay.forwardingPrepare(binding, until: .now.advanced(by: .seconds(5)))
                : await f.relay.forwardingPrepare(binding) }
            await wait { f.relay.checkWaiting == 2 }
            guard case .accepted = await registration.value, case .accepted = await poll.value,
                  case .accepted(let receipt) = await prepared.value else { fatalError("prepare must survive 3s and overlapping callers") }
            expect(receipt.proves(binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!), "prepare expected receipt")
            expect(f.relay.checkConnected, "prepare validates connected boot")
            let methods = f.requests().map { $0["method"] as! String }
            expect(Array(methods.suffix(3)) == ["forwardingRegister", "forwardingSnapshot", "forwardingPrepare"], "catalog, poll, prepare FIFO")
            f.finish()
        }
        for mode in ["receipt-operationId", "receipt-privacyGeneration", "receipt-registryRevision", "receipt-participantId", "receipt-bootId", "receipt-schemaVersion", "receipt-state", "receipt-facts"] {
            let f = await Fixture.make(mode), binding = await f.binding()
            expect(await f.relay.forwardingPrepare(binding) == nil, "prepare rejects \(mode)")
            expect(f.relay.checkClosed, "bad prepare receipt is fail-closed")
            f.finish()
        }
        for budget in [40, 0, -100] {
            let f = await Fixture.make(), binding = await f.binding()
            let hold = Task { await f.relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
            await wait { f.relay.checkPending }
            expect(await f.relay.forwardingPrepare(binding, until: .now.advanced(by: .milliseconds(budget))) == nil, "prepare retains absolute deadline")
            expect(await hold.value == 1 && f.relay.checkConnected, "untransmitted prepare deadline preserves connection")
            expect(!f.requests().contains { $0["method"] as? String == "forwardingPrepare" }, "expired prepare never sent")
            f.finish()
        }
        let combined = await Fixture.make("queued-over-prepare"), combinedBinding = await combined.binding()
        let peer = AudioForwardingPairedDevice(id: combinedBinding.pairedDeviceId, pairingGeneration: UUID())
        let registration = Task { await combined.relay.forwardingRegister(peer) }
        await wait { combined.requests().last?["method"] as? String == "forwardingRegister" }
        let prepared = await combined.relay.forwardingPrepare(combinedBinding, until: .now.advanced(by: .seconds(5)))
        guard case .accepted = await registration.value else { fatalError("long queue fixture registration") }
        expect(prepared == nil && combined.relay.checkClosed, "queue plus prepare cannot extend absolute 5s deadline")
        expect(combined.requests().last?["method"] as? String == "forwardingPrepare", "combined deadline expires after transmission")
        combined.finish()
        let capped = await Fixture.make("over-prepare"), binding = await capped.binding()
        expect(await capped.relay.forwardingPrepare(binding, until: .now.advanced(by: .seconds(20))) == nil, "prepare caps excessive supplied budget")
        expect(capped.relay.checkClosed, "prepare times out at maximum 5s")
        capped.finish()
    }
}
