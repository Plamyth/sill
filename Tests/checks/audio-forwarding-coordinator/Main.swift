import Foundation
import StreamProtocol

@MainActor
final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class Fixture {
    var raw: [String: Any]
    var configuration: AudioForwardingConfiguration?
    var prepares = 0, inspections = 0, commits = 0, fences = 0, inFlight = 0, maximumInFlight = 0
    var corrupt: ((String, LocalAudioParticipantRequest, LocalAudioParticipantReceipt) -> LocalAudioParticipantReceipt)?
    var mutate: ((String) -> Void)?
    var proofAge: Duration = .zero
    var sentry = true, muted = true, proofCurrent = true, missingSnapshot = false, refusedCommit = false
    var gate: Gate?
    var submissionGate: Gate?
    var enforceSubmission = false
    var committedSentry: Bool?
    var committedMute: Bool?

    init(off: Bool = false) throws {
        let device = String(repeating: "a", count: 64), generation = UUID().uuidString
        let config: [String: Any] = ["controllerBootId": UUID().uuidString, "privacyGeneration": UUID().uuidString,
            "registryRevision": "7", "members": [
                ["participantId": "native.sill", "bootId": UUID().uuidString],
                ["participantId": "s23.audio.relay", "bootId": UUID().uuidString]]]
        raw = ["schemaVersion": 1, "revision": "8", "intent": [
            "pairedDeviceId": device, "intentId": UUID().uuidString, "intentRevision": "1",
            "intentGeneration": generation, "inputDesired": !off, "outputDesired": !off,
            "sentryDesired": true, "localMutedDesired": true], "binding": [
                "pairedDeviceId": device, "intentGeneration": generation, "bindingEpoch": UUID().uuidString,
                "transportId": UUID().uuidString, "transportKind": "http", "operationId": UUID().uuidString,
                "phase": "quiescing", "configuration": config]]
        configuration = try JSONDecoder().decode(AudioForwardingConfiguration.self, from: JSONSerialization.data(withJSONObject: config))
    }
    func snapshot() -> AudioForwardingSnapshot { try! JSONDecoder().decode(AudioForwardingSnapshot.self, from: JSONSerialization.data(withJSONObject: raw)) }
    func next() {
        var binding = raw["binding"] as! [String: Any]
        binding["bindingEpoch"] = UUID().uuidString; binding["operationId"] = UUID().uuidString
        binding["transportId"] = UUID().uuidString; binding["phase"] = "quiescing"
        raw["binding"] = binding
    }
    func receipt(_ request: LocalAudioParticipantRequest) -> LocalAudioParticipantReceipt {
        .init(request, state: .quiescent, facts: .init(admissionFenced: true, startsSettled: true,
            mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true))
    }
    func call(_ stage: String, request: LocalAudioParticipantRequest) async -> LocalAudioParticipantReceipt? {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if stage == "prepare" {
            prepares += 1
            if let gate { self.gate = nil; await gate.wait() }
        } else { inspections += 1 }
        mutate?(stage)
        return corrupt?(stage, request, receipt(request)) ?? receipt(request)
    }
    func coordinator(budget: Int = 25_000) -> AudioForwardingCoordinator {
        .init(dependencies: .init(configuration: { self.mutate?("configuration"); return self.configuration }, snapshot: {
            self.mutate?("snapshot"); return self.missingSnapshot ? nil : self.snapshot()
        }, fence: { _ in self.fences += 1 }, prepare: { _, request in
            await self.call("prepare", request: request)
        }, inspect: { _, request in await self.call("inspect", request: request) }, protection: { scope, _ in
            self.mutate?("protection")
            return .init(scope: scope, observedAt: ContinuousClock.now.advanced(by: self.proofAge),
                sentryVerified: self.sentry, localMutedVerified: self.muted)
        }, protectionCurrent: { _ in self.mutate?("protectionCurrent"); return self.proofCurrent }, commit: { payload in
            if let gate = self.submissionGate { await gate.wait() }
            if self.enforceSubmission {
                guard payload.claimSubmission() else { return nil }
                precondition(!payload.claimSubmission())
            }
            self.commits += 1
            self.committedSentry = payload.localProtection.sentryVerified
            self.committedMute = payload.localProtection.localMutedVerified
            let data = try! JSONEncoder().encode(payload)
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(Set(object.keys) == ["intentGeneration", "bindingEpoch", "operationId", "configuration", "receipts", "localProtection"])
            precondition(payload.receipts.count == 2)
            if self.refusedCommit { return .refused(code: "stale_binding_preparation", snapshot: self.snapshot()) }
            var binding = self.raw["binding"] as! [String: Any]
            let intent = self.raw["intent"] as! [String: Any]
            binding["phase"] = intent["inputDesired"] as! Bool || intent["outputDesired"] as! Bool ? "active" : "off"
            self.raw["binding"] = binding
            let accepted = self.snapshot()
            self.mutate?("commit")
            return .accepted(accepted)
        }), budgetMilliseconds: budget)
    }
}

@main
struct Main {
    @MainActor static func blocked(_ value: AudioForwardingCoordinator.Outcome, line: UInt = #line) {
        guard case .blocked = value else { preconditionFailure("준비 실패가 admission으로 바뀜: 줄 \(line)") }
    }
    @MainActor static func settle(_ gate: Gate) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
        precondition(gate.entered)
    }
    @MainActor static func main() async throws {
        var checks = 0
        for desired in [false, true] {
            for proof in [false, true] {
                let f = try Fixture()
                var intent = f.raw["intent"] as! [String: Any]
                intent["sentryDesired"] = desired
                f.raw["intent"] = intent
                f.sentry = proof
                let coordinator = f.coordinator()
                guard case .committed(let scope, _) = await coordinator.reconcile(f.snapshot()) else {
                    preconditionFailure("센츄리 선택과 독립적인 오디오 준비가 거절됨")
                }
                precondition(f.commits == 1 && f.committedSentry == false)
                precondition(coordinator.allowsInput(scope, transport: .http))
                precondition(coordinator.allowsOutput(scope, transport: .http))
                print("PASS manual Sentry independent audio desired=\(desired) proof=\(proof)")
                checks += 1
            }
        }
        for muted in [false, true] {
            let f = try Fixture(off: true)
            f.muted = muted; f.sentry = false
            let coordinator = f.coordinator()
            guard case .committed(let scope, _) = await coordinator.reconcile(f.snapshot()) else {
                preconditionFailure("오디오 OFF 정리가 물리 음소거를 새로 요구함")
            }
            precondition(f.committedMute == muted && f.committedSentry == false)
            precondition(!coordinator.allowsInput(scope, transport: .http) && !coordinator.allowsOutput(scope, transport: .http))
            print("PASS audio OFF preserves actual mute proof=\(muted)")
            checks += 1
        }
        for change in ["none", "invalidate", "cancel", "configuration", "protection"] {
            let f = try Fixture(), gate = Gate(), coordinator = f.coordinator()
            f.enforceSubmission = true
            f.submissionGate = gate
            let work = Task { await coordinator.reconcile(f.snapshot()) }
            await settle(gate)
            switch change {
            case "invalidate": coordinator.invalidate()
            case "cancel": work.cancel()
            case "configuration": f.configuration = nil
            case "protection": f.proofCurrent = false
            default: break
            }
            gate.release()
            let result = await work.value
            if change == "none" {
                guard case .committed = result else { preconditionFailure("정상 제출 표식 누락") }
                precondition(f.commits == 1)
            } else {
                blocked(result)
                precondition(f.commits == 0)
            }
            checks += 1
        }
        for off in [false, true] {
            let f = try Fixture(off: off), coordinator = f.coordinator(), initial = f.snapshot()
            async let first = coordinator.reconcile(initial)
            async let duplicate = coordinator.reconcile(initial)
            let outcomes = await [first, duplicate]
            for result in outcomes {
                guard case .committed(let scope, let current) = result else { preconditionFailure("정상 종료 증명 후 commit 누락") }
                precondition(coordinator.isCurrent(scope) && scope.matches(current, committed: true))
                precondition(coordinator.allowsInput(scope, transport: .http) == !off && coordinator.allowsOutput(scope, transport: .http) == !off)
                precondition(!coordinator.allowsInput(scope, transport: .native) && !coordinator.allowsOutput(scope, transport: .native))
            }
            precondition(f.prepares == 2 && f.inspections == 2 && f.commits == 1 && f.maximumInFlight == 1)
            _ = await coordinator.reconcile(f.snapshot())
            precondition(f.commits == 1)
            let remembered = f.raw["intent"] as! [String: Any]
            f.raw["binding"] = NSNull()
            guard case .waiting = await coordinator.reconcile(f.snapshot()) else { preconditionFailure("해제 의도 삭제") }
            precondition((f.raw["intent"] as! NSDictionary).isEqual(to: remembered))
            f.raw["binding"] = initial.binding.map { binding in
                ["pairedDeviceId": binding.pairedDeviceId.hex, "intentGeneration": binding.intentGeneration.uuidString,
                 "bindingEpoch": UUID().uuidString, "transportId": UUID().uuidString, "transportKind": "http",
                 "operationId": UUID().uuidString, "phase": "quiescing",
                 "configuration": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(binding.configuration))] as [String: Any]
            }
            guard case .committed = await coordinator.reconcile(f.snapshot()) else { preconditionFailure("같은 기억 의도의 새 전송 복원 실패") }
            precondition(f.commits == 2); checks += 9
        }
        for stage in ["prepare", "inspect"] {
            for participant in LocalAudioParticipantID.allCases {
                for fact in 0..<6 {
                    let f = try Fixture()
                    f.corrupt = { actualStage, request, original in
                        guard stage == actualStage, participant == request.participantId else { return original }
                        let flags = (0..<6).map { $0 == fact ? false : true }
                        return .init(request, state: .quiescent, facts: .init(admissionFenced: flags[0], startsSettled: flags[1],
                            mediaDetached: flags[2], callbacksDrained: flags[3], buffersEmpty: flags[4], workersExited: flags[5]))
                    }
                    let coordinator = f.coordinator(); blocked(await coordinator.reconcile(f.snapshot()))
                    precondition(f.commits == 0); checks += 1
                }
                for mismatch in 0..<4 {
                    let f = try Fixture()
                    f.corrupt = { actualStage, request, original in
                        guard actualStage == stage, participant == request.participantId else { return original }
                        let wrong = LocalAudioParticipantRequest(schemaVersion: 1,
                            operationId: mismatch == 0 ? UUID() : request.operationId,
                            privacyGeneration: mismatch == 1 ? UUID() : request.privacyGeneration,
                            registryRevision: mismatch == 2 ? "99" : request.registryRevision,
                            participantId: request.participantId, bootId: mismatch == 3 ? UUID() : request.bootId,
                            budgetMilliseconds: request.budgetMilliseconds)
                        return f.receipt(wrong)
                    }
                    blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 0); checks += 1
                }
            }
        }
        for invalidProof in 1..<5 {
            let f = try Fixture()
            if invalidProof == 0 { f.sentry = false }
            if invalidProof == 1 { f.muted = false }
            if invalidProof == 2 { f.proofAge = .seconds(-1) }
            if invalidProof == 3 { f.proofAge = .seconds(1) }
            if invalidProof == 4 { f.proofCurrent = false }
            blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 0); checks += 1
        }
        for stage in ["prepare", "inspect", "protection", "commit"] {
            let f = try Fixture(); var changed = false
            f.mutate = { actual in if actual == stage && !changed { changed = true; f.next() } }
            blocked(await f.coordinator().reconcile(f.snapshot()))
            precondition(f.commits == (stage == "commit" ? 1 : 0)); checks += 1
        }
        do {
            let f = try Fixture(), gate = Gate(); f.gate = gate
            let coordinator = f.coordinator()
            let old = Task { await coordinator.reconcile(f.snapshot()) }
            await settle(gate); old.cancel(); gate.release()
            blocked(await old.value); precondition(f.commits == 0); checks += 1
        }
        do {
            let f = try Fixture(), gate = Gate(); f.gate = gate
            let coordinator = f.coordinator(), oldSnapshot = f.snapshot()
            let old = Task { await coordinator.reconcile(oldSnapshot) }
            await settle(gate); f.next()
            let replacement = Task { await coordinator.reconcile(f.snapshot()) }
            await Task.yield(); gate.release()
            blocked(await old.value)
            guard case .committed(let scope, _) = await replacement.value else { preconditionFailure("새 pending 소비 실패") }
            precondition(f.commits == 1 && f.maximumInFlight == 1 && coordinator.isCurrent(scope))
            blocked(await coordinator.reconcile(oldSnapshot))
            precondition(coordinator.isCurrent(scope) && f.commits == 1); checks += 3
        }
        do {
            let f = try Fixture(), gate = Gate(); f.gate = gate
            let coordinator = f.coordinator(budget: 50)
            let old = Task { await coordinator.reconcile(f.snapshot()) }
            await settle(gate)
            blocked(await old.value)
            precondition(f.inFlight == 1)
            f.next()
            let replacement = Task { await coordinator.reconcile(f.snapshot()) }
            try await Task.sleep(for: .milliseconds(10))
            precondition(f.prepares == 1 && f.maximumInFlight == 1)
            gate.release()
            guard case .committed = await replacement.value else { preconditionFailure("실제 호출 종료 뒤 새 pending 복구 실패") }
            precondition(f.maximumInFlight == 1 && f.commits == 1); checks += 1
        }
        for mutationAt in [2, 3] {
            for change in ["invalidate", "cancel", "configuration", "protection", "configurationCallback"] {
                let f = try Fixture(), coordinator = f.coordinator()
                var checksOfProtection = 0
                var configurationMutationArmed = false
                var task: Task<AudioForwardingCoordinator.Outcome, Never>?
                f.mutate = { stage in
                    if configurationMutationArmed, stage == "configuration" {
                        configurationMutationArmed = false
                        coordinator.invalidate()
                        return
                    }
                    guard stage == "protectionCurrent" else { return }
                    checksOfProtection += 1
                    guard checksOfProtection == mutationAt else { return }
                    switch change {
                    case "invalidate": coordinator.invalidate()
                    case "cancel": task?.cancel()
                    case "configuration": f.configuration = nil
                    case "configurationCallback": configurationMutationArmed = true
                    default: f.proofCurrent = false
                    }
                }
                task = Task { await coordinator.reconcile(f.snapshot()) }
                blocked(await task!.value)
                precondition(f.commits == 0); checks += 1
            }
        }
        for callback in ["configuration", "protectionCurrent"] {
            let f = try Fixture(), coordinator = f.coordinator()
            guard case .committed(let scope, _) = await coordinator.reconcile(f.snapshot()) else { preconditionFailure("정상 commit 누락") }
            f.mutate = { stage in if stage == callback { coordinator.invalidate() } }
            precondition(!coordinator.isCurrent(scope)); checks += 1
        }
        do {
            let f = try Fixture(); f.missingSnapshot = true
            blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 0); checks += 1
        }
        do {
            let f = try Fixture(); f.refusedCommit = true
            blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 1); checks += 1
        }
        do {
            let f = try Fixture()
            f.mutate = { stage in if stage == "prepare" { f.configuration = nil } }
            blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 0); checks += 1
        }
        do {
            let f = try Fixture()
            f.mutate = { stage in if stage == "commit" { f.proofCurrent = false } }
            blocked(await f.coordinator().reconcile(f.snapshot())); precondition(f.commits == 1); checks += 1
        }
        do {
            let f = try Fixture(), coordinator = f.coordinator(), pending = f.snapshot()
            guard case .committed(let scope, _) = await coordinator.reconcile(pending) else { preconditionFailure("정상 commit 누락") }
            f.proofCurrent = false
            blocked(await coordinator.reconcile(pending))
            precondition(!coordinator.isCurrent(scope) && f.commits == 1); checks += 1
        }
        print("호스트 음성 소비 계약 \(checks)개 통과 · 합성 어댑터이며 실제 HAL/센츄리/기기 시험 아님")
    }
}
