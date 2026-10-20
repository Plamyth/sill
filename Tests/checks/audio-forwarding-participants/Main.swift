import Foundation

@MainActor
final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class Backend {
    var nativeStops = 0, relayStops = 0, reads = 0, inFlight = 0, maximumInFlight = 0
    var nativeGate: Gate?
    var succeeded = true
    var fact: Int?, unknown = false
    var nativeHook: (() -> Void)?
    var relayRequest: LocalAudioParticipantRequest?
    var forwardingContext: LocalAudioParticipantRegistry.ForwardingPreparation?
    var corrupt: ((LocalAudioParticipantRequest) -> LocalAudioParticipantRequest)?
    func stop(native: Bool) async -> Bool {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if native {
            nativeStops += 1
            if let gate = nativeGate { nativeGate = nil; await gate.wait() }
        } else { relayStops += 1 }
        return succeeded
    }
    func facts(fenced: Bool) -> LocalAudioParticipantFacts {
        reads += 1
        let action = nativeHook; nativeHook = nil; action?()
        let values: [Bool?] = (0..<6).map { $0 == fact ? (unknown ? nil : false) : true }
        return .init(admissionFenced: fenced ? values[0] : false, startsSettled: values[1],
            mediaDetached: values[2], callbacksDrained: values[3], buffersEmpty: values[4], workersExited: values[5])
    }
    func receipt(_ request: LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt {
        .init(corrupt?(request) ?? request, state: .quiescent,
            facts: .init(admissionFenced: true, startsSettled: true, mediaDetached: true,
                         callbacksDrained: true, buffersEmpty: true, workersExited: true))
    }
}

@MainActor
final class Fixture {
    let startup = NativeAudioStartup()
    let backend = Backend()
    var registry: LocalAudioParticipantRegistry { startup.participants }
    lazy var adapter = AudioForwardingParticipants(registry: registry)
    let controller = UUID(), privacy = UUID(), intentA = UUID(), generationA = UUID()
    init(legacyRelay: Bool = false, initialize: Bool = true) {
        if initialize { startup.construct { () } }
        startup.revoke = { await self.backend.stop(native: true) }
        startup.readFacts = { self.backend.facts(fenced: self.registry.isFenced) }
        registerRelay(supports: !legacyRelay)
    }
    func registerRelay(supports: Bool = true) {
        registry.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { request in
            self.backend.relayRequest = request
            guard await self.backend.stop(native: false) else { return .init(request, state: .unknown, facts: .unknown) }
            return self.backend.receipt(request)
        }, inspect: { id in
            guard let request = self.backend.relayRequest, request.operationId == id else { return nil }
            return self.backend.receipt(request)
        }, supportsForwarding: supports, forwardingPrepare: { preparation in
            self.backend.forwardingContext = preparation
            self.backend.relayRequest = preparation.request
            guard await self.backend.stop(native: false) else { return nil }
            return self.backend.receipt(preparation.request)
        }))
    }
    func scope(device: String = "a", native: Bool = false) -> AudioForwardingCoordinator.Scope {
        let configuration = try! AudioForwardingConfiguration(controllerBootId: controller,
            privacyGeneration: privacy, membership: registry.snapshot)
        let generation = device == "a" ? generationA : UUID(), intent = device == "a" ? intentA : UUID()
        let peer = String(repeating: device, count: 64)
        let data: [String: Any] = ["schemaVersion": 1, "revision": "1", "intent": ["pairedDeviceId": peer,
            "intentId": intent.uuidString, "intentRevision": "1", "intentGeneration": generation.uuidString,
            "inputDesired": true, "outputDesired": true, "sentryDesired": true, "localMutedDesired": true],
            "binding": ["pairedDeviceId": peer, "intentGeneration": generation.uuidString,
                "bindingEpoch": UUID().uuidString, "transportId": UUID().uuidString,
                "transportKind": native ? "native" : "http", "operationId": UUID().uuidString,
                "phase": "quiescing", "configuration": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))]]
        return .init(try! JSONDecoder().decode(AudioForwardingSnapshot.self, from: JSONSerialization.data(withJSONObject: data)))!
    }
    func request(_ scope: AudioForwardingCoordinator.Scope, _ id: LocalAudioParticipantID = .native) -> LocalAudioParticipantRequest {
        scope.binding.participantRequest(for: id, budgetMilliseconds: 2000)!
    }
    func prepareAll(_ scope: AudioForwardingCoordinator.Scope, using supplied: AudioForwardingParticipants? = nil) async -> Bool {
        let adapter = supplied ?? self.adapter
        for id in LocalAudioParticipantID.allCases {
            let request = request(scope, id)
            guard let receipt = await adapter.prepare(scope, request: request, until: ContinuousClock.now.advanced(by: .seconds(2))), receipt.proves(request) else { return false }
        }
        return true
    }
    func inspectAll(_ scope: AudioForwardingCoordinator.Scope, using supplied: AudioForwardingParticipants? = nil) async -> Bool {
        let adapter = supplied ?? self.adapter
        for id in LocalAudioParticipantID.allCases {
            let request = request(scope, id)
            guard let receipt = await adapter.inspect(scope, request: request, until: ContinuousClock.now.advanced(by: .seconds(2))), receipt.proves(request) else { return false }
        }
        return true
    }
}

@main
struct Main {
    @MainActor static func settle(_ gate: Gate) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
        precondition(gate.entered)
    }
    @MainActor static func main() async throws {
        var checks = 0
        do {
            let f = Fixture(), first = f.scope(), resumed = f.scope(), ipad = f.scope(device: "b", native: true)
            for scope in [first, resumed, ipad] {
                precondition(f.adapter.begin(scope))
                let prepared = await f.prepareAll(scope), inspected = await f.inspectAll(scope)
                precondition(prepared && inspected && f.registry.isFenced)
                precondition(f.backend.forwardingContext?.intentGeneration == scope.binding.intentGeneration &&
                             f.backend.forwardingContext?.bindingEpoch == scope.binding.bindingEpoch)
            }
            precondition(f.backend.nativeStops == 3 && f.backend.relayStops == 3 && f.backend.maximumInFlight == 1)
            precondition(!f.adapter.begin(first))
            let stale = await f.adapter.prepare(first, request: f.request(first), until: ContinuousClock.now.advanced(by: .seconds(1)))
            precondition(stale == nil)
            let current = await f.inspectAll(ipad); precondition(current); checks += 7
        }
        do {
            let f = Fixture(), scope = f.scope(), request = f.request(scope)
            precondition(f.adapter.begin(scope))
            async let first = f.adapter.prepare(scope, request: request, until: ContinuousClock.now.advanced(by: .seconds(1)))
            async let second = f.adapter.prepare(scope, request: request, until: ContinuousClock.now.advanced(by: .seconds(1)))
            let values = await [first, second]
            precondition(values.allSatisfy { $0?.proves(request) == true } && f.backend.nativeStops == 1)
            let early = await f.adapter.inspect(scope, request: request, until: ContinuousClock.now.advanced(by: .seconds(1)))
            precondition(early == nil)
            let all = await f.prepareAll(scope); precondition(all && f.backend.nativeStops == 1 && f.backend.relayStops == 1)
            let fresh = await f.inspectAll(scope); precondition(fresh); checks += 4
        }
        for reason in ["timeout", "cancel", "invalidate", "membership"] {
            let f = Fixture(), gate = Gate(); f.backend.nativeGate = gate
            let first = f.scope(), adapter = f.adapter
            precondition(adapter.begin(first))
            let old = Task { await adapter.prepare(first, request: f.request(first),
                until: ContinuousClock.now.advanced(by: reason == "timeout" ? .milliseconds(50) : .seconds(2))) }
            await settle(gate)
            if reason == "timeout" { let value = await old.value; precondition(value == nil) }
            if reason == "cancel" { old.cancel(); let value = await old.value; precondition(value == nil) }
            if reason == "invalidate" { adapter.invalidate() }
            if reason == "membership" { f.registerRelay() }
            precondition(f.registry.authenticatedLocalReturnUnavailableReason != nil)
            let next = f.scope(device: "b", native: true), replacement = AudioForwardingParticipants(registry: f.registry)
            precondition(replacement.begin(next))
            let new = Task { await replacement.prepare(next, request: f.request(next), until: ContinuousClock.now.advanced(by: .seconds(2))) }
            try await Task.sleep(for: .milliseconds(10))
            precondition(f.backend.nativeStops == 1 && f.backend.maximumInFlight == 1)
            gate.release()
            let previous = await old.value, result = await new.value
            precondition(previous == nil && result?.proves(f.request(next)) == true && f.backend.nativeStops == 2 && f.backend.maximumInFlight == 1)
            adapter.invalidate()
            let prepared = await f.prepareAll(next, using: replacement), inspected = await f.inspectAll(next, using: replacement)
            precondition(prepared && inspected); checks += 4
        }
        for unknown in [false, true] {
            for index in 0..<6 {
                let f = Fixture(), scope = f.scope(); f.backend.fact = index; f.backend.unknown = unknown
                precondition(f.adapter.begin(scope))
                let receipt = await f.adapter.prepare(scope, request: f.request(scope), until: ContinuousClock.now.advanced(by: .seconds(1)))
                precondition(receipt == nil && f.backend.relayStops == 0); checks += 1
            }
        }
        for mismatch in 0..<4 {
            let f = Fixture(), scope = f.scope(); precondition(f.adapter.begin(scope))
            f.backend.corrupt = { request in .init(schemaVersion: 1,
                operationId: mismatch == 0 ? UUID() : request.operationId,
                privacyGeneration: mismatch == 1 ? UUID() : request.privacyGeneration,
                registryRevision: mismatch == 2 ? "999" : request.registryRevision,
                participantId: request.participantId, bootId: mismatch == 3 ? UUID() : request.bootId,
                budgetMilliseconds: request.budgetMilliseconds) }
            let prepared = await f.prepareAll(scope); precondition(!prepared); checks += 1
        }
        do {
            let f = Fixture(), first = f.scope(), next = f.scope(device: "b")
            precondition(f.adapter.begin(first))
            f.backend.nativeHook = { precondition(f.adapter.begin(next)) }
            let stale = await f.adapter.prepare(first, request: f.request(first), until: ContinuousClock.now.advanced(by: .seconds(1)))
            precondition(stale == nil)
            let prepared = await f.prepareAll(next), inspected = await f.inspectAll(next)
            precondition(prepared && inspected); checks += 2
        }
        do {
            let f = Fixture(), first = f.scope(); precondition(f.adapter.begin(first))
            let prepared = await f.prepareAll(first); precondition(prepared)
            precondition(f.registry.authenticatedLocalReturnUnavailableReason == nil && f.registry.unavailableReason != nil)
            let operation = UUID(), membership = f.registry.snapshot
            let ticket = f.registry.beginLocalReturn(operationId: operation, privacyGeneration: f.privacy, membership: membership)!
            let next = f.scope(device: "b", native: true)
            precondition(!f.adapter.begin(next))
            let stopped = await f.registry.fenceAndQuiesce(operationId: operation, privacyGeneration: f.privacy, membership: membership, budgetMilliseconds: 2000)
            let inspected = await f.registry.inspectAll(operationId: operation, privacyGeneration: f.privacy, membership: membership)
            precondition(stopped && inspected && f.registry.proofCurrent(operationId: operation, privacyGeneration: f.privacy, membership: membership))
            f.registry.endLocalReturn(ticket)
            precondition(!f.registry.proofCurrent(operationId: operation, privacyGeneration: f.privacy, membership: membership) && f.registry.isFenced)
            precondition(f.adapter.begin(next))
            let ready = await f.prepareAll(next), verified = await f.inspectAll(next)
            f.registry.endLocalReturn(ticket)
            let stillReady = await f.inspectAll(next)
            precondition(ready && verified && stillReady); checks += 5
        }
        do {
            let f = Fixture(), gate = Gate(); f.backend.nativeGate = gate
            let operation = UUID(), membership = f.registry.snapshot
            let ticket = f.registry.beginLocalReturn(operationId: operation, privacyGeneration: f.privacy, membership: membership)!
            let local = Task { await f.registry.fenceAndQuiesce(operationId: operation, privacyGeneration: f.privacy, membership: membership, budgetMilliseconds: 2000) }
            await settle(gate)
            precondition(!f.adapter.begin(f.scope()))
            f.registry.endLocalReturn(ticket)
            precondition(!f.adapter.begin(f.scope()) && f.registry.authenticatedLocalReturnUnavailableReason != nil)
            gate.release(); let result = await local.value
            precondition(!result && !f.adapter.begin(f.scope()) && f.registry.isFenced); checks += 3
        }
        do {
            let f = Fixture(legacyRelay: true)
            precondition(!f.adapter.begin(f.scope()) && !f.registry.isFenced)
            let operation = UUID(), membership = f.registry.snapshot
            let stopped = await f.registry.fenceAndQuiesce(operationId: operation, privacyGeneration: f.privacy, membership: membership, budgetMilliseconds: 2000)
            let inspected = await f.registry.inspectAll(operationId: operation, privacyGeneration: f.privacy, membership: membership)
            precondition(stopped && inspected && f.registry.authenticatedLocalReturnUnavailableReason != nil && f.registry.isFenced); checks += 2
        }
        do {
            let f = Fixture(initialize: false), first = f.scope()
            precondition(f.adapter.begin(first))
            let old = Task { await f.adapter.prepare(first, request: f.request(first), until: ContinuousClock.now.advanced(by: .milliseconds(50))) }
            let receipt = await old.value; precondition(receipt == nil && f.backend.nativeStops == 0)
            f.startup.construct { () }
            let next = f.scope(); precondition(f.adapter.begin(next))
            let ready = await f.prepareAll(next), inspected = await f.inspectAll(next)
            precondition(ready && inspected && f.backend.nativeStops == 1); checks += 2
        }
        print("실제 등록부·NativeAudioStartup 기반 비활성 계약 \(checks)개 통과 · PCM/HAL/설치/실기기 수용 아님")
    }
}
