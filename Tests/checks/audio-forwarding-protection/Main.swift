import Foundation
import StreamProtocol

@MainActor
final class FakeHAL: HostAudioPrivacyHAL {
    var value = PrivacyAudioSnapshot(devices: [
        .init(id: 1, uid: "builtin-mic", transport: .builtIn, plugin: nil, inputChannels: 1, outputChannels: 0, inputMuted: false, outputMuted: nil),
        .init(id: 2, uid: "builtin-speaker", transport: .builtIn, plugin: nil, inputChannels: 0, outputChannels: 2, inputMuted: nil, outputMuted: false),
        .init(id: 3, uid: "BlackHole2ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole2ch", inputChannels: 2, outputChannels: 2, inputMuted: nil, outputMuted: nil),
        .init(id: 4, uid: "BlackHole16ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole16ch", inputChannels: 16, outputChannels: 16, inputMuted: nil, outputMuted: nil)
    ], input: 1, output: 2, systemOutput: 2)
    var reads = 0, writes = 0, restorations = 0, observations = 0
    var readFails = false
    var hook: (() -> Void)?
    var changed: (@MainActor () -> Void)?
    func read() throws -> PrivacyAudioSnapshot {
        reads += 1
        let action = hook; hook = nil; action?()
        if readFails { throw PrivacyAudioFailure.readback }
        return value
    }
    func write(_ change: PrivacyAudioWrite) -> Bool {
        writes += 1
        switch change {
        case .mute(let id, let scope):
            guard let i = value.devices.firstIndex(where: { $0.id == id }) else { return false }
            if scope == .input { value.devices[i].inputMuted = true } else { value.devices[i].outputMuted = true }
        case .select(let direction, let id):
            switch direction { case .input: value.input = id; case .output: value.output = id; case .systemOutput: value.systemOutput = id }
        }
        return true
    }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        observations += 1
        self.changed = changed; return true
    }
    func restoreLocal(_ state: LocalAudioState) -> Bool { restorations += 1; return false }
}

@MainActor
final class AuthenticationGate {
    var entered = false
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { entered = true; return await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: false); continuation = nil }
}

@MainActor
final class Fixture {
    let hal = FakeHAL()
    let admission = SentryAdmission()
    let startup = NativeAudioStartup()
    var audio: HostAudioPrivacy!
    var sentry: HostSentry!
    var adapter: AudioForwardingProtection!
    var configuration: AudioForwardingConfiguration?
    var surfaceReads = 0, surfaceWrites = 0, persistenceWrites = 0
    var surfaceGood = true, persistenceGood = true
    var surfaceHook: (() -> Void)?
    var configurationHook: (() -> Void)?
    var authentication: AuthenticationGate?
    let controllerBoot = UUID()

    init() {
        audio = HostAudioPrivacy(hal: hal, persist: { self.persistenceWrites += 1; return self.persistenceGood },
            saveLocal: { _ in self.persistenceWrites += 1; return self.persistenceGood },
            clearLatch: { self.persistenceWrites += 1; return false },
            authenticateLocal: { _ in await self.authentication?.wait() ?? false }, nativeStartup: startup)
        startup.construct { () }
        audio.revokeForLocalReturn = { true }
        audio.inspectForLocalReturn = { .init(admissionFenced: self.audio.participants.isFenced, startsSettled: true,
            mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true) }
        registerRelay()
        precondition(audio.armAndVerify())
        bindProtection()
    }
    func bindProtection() {
        sentry = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in self.persistenceWrites += 1; return self.persistenceGood }, surfaces: .init(engage: { self.surfaceWrites += 1; return self.surfaceGood }, verify: {
                self.surfaceReads += 1
                let action = self.surfaceHook; self.surfaceHook = nil; action?()
                return self.surfaceGood
            }, release: { self.surfaceWrites += 1; return false }, reason: { nil }),
            audioReady: { self.audio.forwardingHealth() }, localReturnUnavailableReason: { nil })
        precondition(sentry.reconcile())
        configure()
        adapter = .init(audio: audio, sentry: sentry, configuration: {
            let action = self.configurationHook; self.configurationHook = nil; action?()
            return self.configuration
        })
        hal.writes = 0; hal.observations = 0; surfaceWrites = 0; persistenceWrites = 0
    }
    func assertReadOnly() {
        precondition(hal.writes == 0 && hal.restorations == 0 && hal.observations == 0 &&
                     surfaceWrites == 0 && persistenceWrites == 0,
                     "보호 조회는 HAL·감시·표면·영구 상태를 변경하면 안 됩니다.")
    }
    func registerRelay() {
        audio.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { request in
            .init(request, state: .quiescent, facts: .init(admissionFenced: true, startsSettled: true,
                mediaDetached: true, callbacksDrained: true, buffersEmpty: true, workersExited: true))
        }, inspect: { _ in nil }))
    }
    func configure() {
        configuration = try! .init(controllerBootId: controllerBoot, privacyGeneration: audio.forwardingPrivacyGeneration,
                                    membership: audio.participants.snapshot)
    }
    func scope() -> AudioForwardingCoordinator.Scope {
        let configuration = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(self.configuration!))
        let device = String(repeating: "a", count: 64), generation = UUID().uuidString
        let value: [String: Any] = ["schemaVersion": 1, "revision": "1", "intent": [
            "pairedDeviceId": device, "intentId": UUID().uuidString, "intentRevision": "1", "intentGeneration": generation,
            "inputDesired": true, "outputDesired": true, "sentryDesired": true, "localMutedDesired": true], "binding": [
                "pairedDeviceId": device, "intentGeneration": generation, "bindingEpoch": UUID().uuidString,
                "transportId": UUID().uuidString, "transportKind": "http", "operationId": UUID().uuidString,
                "phase": "quiescing", "configuration": configuration]]
        return .init(try! JSONDecoder().decode(AudioForwardingSnapshot.self, from: JSONSerialization.data(withJSONObject: value)))!
    }
    func read(_ scope: AudioForwardingCoordinator.Scope? = nil) -> AudioForwardingCoordinator.ProtectionReadback? {
        adapter.readback(scope ?? self.scope(), until: ContinuousClock.now.advanced(by: .seconds(1)))
    }
    func changeConfiguration(_ mutate: (inout [String: Any]) -> Void) {
        var value = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration!)) as! [String: Any]
        mutate(&value)
        configuration = try! JSONDecoder().decode(AudioForwardingConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func close() { audio.stop() }
}

@main
struct Main {
    @MainActor static func main() async throws {
        var checks = 0
        do {
            let f = Fixture(); defer { f.close() }
            precondition(f.audio.verify())
            let proof = f.read()!
            precondition(f.adapter.current(proof) && f.surfaceReads > 1 && f.hal.reads > 2)
            f.assertReadOnly()
            let forged = AudioForwardingCoordinator.ProtectionReadback(scope: proof.scope, observedAt: ContinuousClock.now,
                sentryVerified: true, localMutedVerified: true)
            precondition(!f.adapter.current(forged)); checks += 4
        }
        do {
            let f = Fixture(); defer { f.close() }
            let configuration = f.configuration!, membership = f.audio.participants.snapshot
            let fenced = await f.audio.participants.fenceAndQuiesce(operationId: UUID(),
                privacyGeneration: configuration.privacyGeneration, membership: membership, budgetMilliseconds: 1000)
            precondition(fenced)
            precondition(f.audio.participants.isFenced && !f.audio.verify())
            f.bindProtection()
            let proof = f.read()!
            precondition(f.adapter.current(proof))
            let audioProof = f.audio.forwardingProof()!, sentryProof = f.sentry.forwardingProof()!
            let audioReads = f.hal.reads, surfaceReads = f.surfaceReads
            for _ in 0..<3 {
                precondition(f.audio.forwardingHealth())
                precondition(f.audio.forwardingProof() == audioProof && f.sentry.forwardingProof() == sentryProof,
                             "동일한 보호 관측의 반복 조회는 proof 세대를 유지해야 합니다.")
                precondition(f.adapter.current(proof), "건강검사가 coordinator의 기존 증명을 무효화하면 안 됩니다.")
            }
            precondition(f.hal.reads == audioReads + 6 && f.surfaceReads == surfaceReads + 3)
            precondition(f.audio.participants.isFenced && !f.audio.verify())
            f.assertReadOnly(); checks += 11
        }
        for failure in ["hal-read", "hal-unsafe", "surface"] {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!, audioProof = f.audio.forwardingProof()!, sentryProof = f.sentry.forwardingProof()!
            let snapshot = f.hal.value
            switch failure {
            case "hal-read": f.hal.readFails = true
            case "hal-unsafe": f.hal.value.devices[0].inputMuted = false
            default: f.surfaceGood = false
            }
            if failure == "surface" {
                precondition(f.sentry.forwardingProof() == nil && !f.sentry.forwardingProofCurrent(sentryProof))
            } else {
                precondition(!f.audio.forwardingHealth() && !f.audio.forwardingProofCurrent(audioProof))
            }
            precondition(!f.adapter.current(proof))
            f.hal.readFails = false; f.hal.value = snapshot; f.surfaceGood = true
            precondition(f.audio.forwardingHealth() && f.sentry.forwardingProof() != nil)
            precondition(!f.adapter.current(proof), "실패 후 동일 관측으로 복구돼도 이전 증명은 되살아나면 안 됩니다.")
            if failure == "surface" { precondition(!f.sentry.forwardingProofCurrent(sentryProof)) }
            else { precondition(!f.audio.forwardingProofCurrent(audioProof)) }
            precondition(f.read() != nil)
            f.assertReadOnly(); checks += 7
        }
        for change in ["devices", "input-default", "output-defaults"] {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!, audioProof = f.audio.forwardingProof()!, original = f.hal.value
            switch change {
            case "devices":
                f.hal.value.devices.append(.init(id: 5, uid: "muted-usb", transport: .other, plugin: nil,
                    inputChannels: 2, outputChannels: 2, inputMuted: true, outputMuted: true))
            case "input-default":
                let device = f.hal.value.devices[2]
                f.hal.value.devices[2] = .init(id: 30, uid: device.uid, transport: device.transport, plugin: device.plugin,
                    inputChannels: device.inputChannels, outputChannels: device.outputChannels,
                    inputMuted: device.inputMuted, outputMuted: device.outputMuted)
                f.hal.value.input = 30
            default:
                let device = f.hal.value.devices[3]
                f.hal.value.devices[3] = .init(id: 40, uid: device.uid, transport: device.transport, plugin: device.plugin,
                    inputChannels: device.inputChannels, outputChannels: device.outputChannels,
                    inputMuted: device.inputMuted, outputMuted: device.outputMuted)
                f.hal.value.output = 40; f.hal.value.systemOutput = 40
            }
            let plan = try f.hal.value.plan()
            precondition(plan.isEmpty)
            precondition(f.audio.forwardingHealth() && !f.audio.forwardingProofCurrent(audioProof) && !f.adapter.current(proof))
            let changed = f.audio.forwardingProof()!
            precondition(changed != audioProof && f.audio.forwardingProof() == changed)
            f.hal.value = original
            precondition(f.audio.forwardingHealth() && !f.audio.forwardingProofCurrent(audioProof) &&
                         !f.audio.forwardingProofCurrent(changed) && !f.adapter.current(proof))
            f.assertReadOnly(); checks += 5
        }
        for invalid in 0..<10 {
            let f = Fixture(); defer { f.close() }
            switch invalid {
            case 0: f.hal.value.devices[0].inputMuted = false
            case 1: f.hal.value.devices[1].outputMuted = false
            case 2: f.hal.value.devices[0].inputMuted = nil
            case 3: f.hal.value.devices[1].outputMuted = nil
            case 4: f.hal.value.input = 1
            case 5: f.hal.value.output = 2
            case 6: f.hal.value.systemOutput = 2
            case 7: f.hal.readFails = true
            case 8: f.surfaceGood = false
            default: f.hal.value.devices.append(.init(id: 5, uid: "unknown-usb", transport: .other, plugin: nil,
                inputChannels: 2, outputChannels: 0, inputMuted: nil, outputMuted: nil))
            }
            precondition(f.read() == nil)
            f.assertReadOnly(); checks += 2
        }
        for invalidation in ["hal-stop", "hal-member", "hal-health-aba", "surface-change", "surface-audio", "surface-health-aba", "config-invalidate", "config-audio", "config-sentry", "config-member", "surface-roundtrip", "config-roundtrip"] {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!
            switch invalidation {
            case "hal-stop": f.hal.hook = { f.audio.stop() }
            case "hal-member": f.hal.hook = { f.registerRelay() }
            case "hal-health-aba": f.hal.hook = {
                f.hal.readFails = true; precondition(!f.audio.forwardingHealth()); f.hal.readFails = false
            }
            case "surface-change": f.surfaceHook = { f.sentry.membershipWillChange() }
            case "surface-audio": f.surfaceHook = { f.audio.stop() }
            case "surface-health-aba": f.surfaceHook = {
                f.surfaceGood = false; precondition(f.sentry.forwardingProof() == nil); f.surfaceGood = true
            }
            case "config-invalidate": f.configurationHook = { f.adapter.invalidate() }
            case "config-audio": f.configurationHook = { f.audio.stop() }
            case "config-sentry": f.configurationHook = { f.sentry.membershipWillChange() }
            case "surface-roundtrip": f.surfaceHook = { let peer = ObjectIdentifier(f.hal); f.admission.register(peer, externalRoute: true); f.admission.remove(peer) }
            case "config-roundtrip": f.configurationHook = { let peer = ObjectIdentifier(f.hal); f.admission.register(peer, externalRoute: true); f.admission.remove(peer) }
            default: f.configurationHook = { f.registerRelay() }
            }
            precondition(f.read() == nil && !f.adapter.current(proof))
            if invalidation == "hal-health-aba" || invalidation == "surface-health-aba" {
                precondition(f.read() != nil && !f.adapter.current(proof))
                f.assertReadOnly()
            }
            checks += 1
        }
        for mutation in 0..<4 {
            let f = Fixture(); defer { f.close() }
            let scope = f.scope()
            f.changeConfiguration { value in
                if mutation == 0 { value["controllerBootId"] = UUID().uuidString }
                if mutation == 1 { value["privacyGeneration"] = UUID().uuidString }
                if mutation == 2 { value["registryRevision"] = "999" }
                if mutation == 3 { var members = value["members"] as! [[String: Any]]; members[0]["bootId"] = UUID().uuidString; value["members"] = members }
            }
            precondition(f.read(scope) == nil)
            if mutation != 0 { precondition(f.read() == nil) }
            checks += 1
        }
        for event in ["hal", "surface", "member", "admission", "stop", "new-proof", "audio-reconcile", "sentry-reconcile", "config-invalidate", "config-audio", "config-sentry", "config-member", "admission-roundtrip"] {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!
            switch event {
            case "hal": f.hal.changed?(); _ = f.audio.reconcile()
            case "surface": f.sentry.surfacesChanged()
            case "member": f.registerRelay(); f.configure()
            case "admission": f.admission.register(ObjectIdentifier(f), externalRoute: true)
            case "admission-roundtrip": let peer = ObjectIdentifier(f.hal); f.admission.register(peer, externalRoute: true); f.admission.remove(peer)
            case "stop": f.audio.stop()
            case "new-proof": _ = f.read(proof.scope)
            case "audio-reconcile": precondition(f.audio.reconcile())
            case "sentry-reconcile": precondition(f.sentry.reconcile())
            case "config-invalidate": f.configurationHook = { f.adapter.invalidate() }
            case "config-audio": f.configurationHook = { f.audio.stop() }
            case "config-sentry": f.configurationHook = { f.sentry.membershipWillChange() }
            default: f.configurationHook = { f.registerRelay() }
            }
            precondition(!f.adapter.current(proof)); checks += 1
        }
        do {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!, gate = AuthenticationGate(); f.authentication = gate
            let request = Task { await f.audio.requestLocalReturn(budgetMilliseconds: 1000) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
            precondition(gate.entered && !f.adapter.current(proof) && f.read() == nil)
            gate.release(); let returned = await request.value; precondition(!returned)
            precondition(!f.adapter.current(proof)); checks += 2
        }
        do {
            let f = Fixture(); defer { f.close() }
            var invalidations = 0
            f.audio.forwardingInvalidated = { invalidations += 1 }
            precondition(f.audio.forwardingHealth() && f.read() != nil)
            precondition(invalidations == 0)
            f.hal.changed?()
            precondition(invalidations == 1); checks += 1
        }
        for failure in ["audio-persistence", "sentry-persistence", "missing-member"] {
            let f = Fixture(); defer { f.close() }
            let proof = f.read()!
            if failure == "missing-member" { f.audio.participants.unregister(.relay) }
            else {
                f.persistenceGood = false
                if failure == "audio-persistence" { precondition(!f.audio.armAndVerify()) }
                else { precondition(!f.sentry.reconcile()) }
            }
            precondition(!f.adapter.current(proof) && f.read() == nil); checks += 1
        }
        do {
            let f = Fixture(); defer { f.close() }
            let missingOriginal = HostAudioPrivacy(hal: f.hal, latched: true, nativeStartup: f.startup)
            precondition(missingOriginal.forwardingProof() == nil && f.hal.writes == 0); checks += 1
        }
        do {
            let f = Fixture(); defer { f.close() }
            let peer = ObjectIdentifier(f.hal)
            f.admission.register(peer, externalRoute: true); f.admission.admit(peer)
            f.admission.update(verified: false, persistenceHealthy: true, reason: "전송 종료 확인 중")
            precondition(!f.admission.allowsActions(peer))
            precondition(f.read() != nil && !f.admission.allowsActions(peer)); checks += 1
        }
        do {
            let f = Fixture(); defer { f.close() }
            precondition(f.adapter.readback(f.scope(), until: ContinuousClock.now.advanced(by: .seconds(-1))) == nil)
            let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return f.read() == nil }
            let cancelled = await task.value; precondition(cancelled); checks += 2
        }
        print("실제 보호 모델 기반 합성 계약 \(checks)개 통과 · HAL/표면 조작·설치·실기기 수용 아님")
    }
}
