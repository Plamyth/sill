import Foundation
import StreamProtocol
import Darwin

@MainActor private final class Gate {
    var entered = false
    var released = false
    var exited = false
    func wait() async {
        entered = true
        while !released && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        exited = true
    }
}

@MainActor private final class HAL: HostAudioPrivacyHAL {
    static let local = PrivacyAudioSnapshot(devices: [
        .init(id: 10, uid: "fixture-local", transport: .builtIn, plugin: nil,
              inputChannels: 1, outputChannels: 2, inputMuted: false, outputMuted: false),
        .init(id: 20, uid: "BlackHole2ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole2ch",
              inputChannels: 2, outputChannels: 2),
        .init(id: 30, uid: "BlackHole16ch_UID", transport: .virtual, plugin: "audio.existential.BlackHole16ch",
              inputChannels: 16, outputChannels: 16)
    ], input: 10, output: 10, systemOutput: 10)
    var snapshot = local
    var reads = 0, writes = 0, restores = 0, observations = 0
    var readFails = false
    var restoreSucceeds = true
    var readHook: (() -> Void)?
    func read() throws -> PrivacyAudioSnapshot {
        reads += 1
        readHook?()
        if readFails { throw PrivacyAudioFailure.readback }
        return snapshot
    }
    func write(_ change: PrivacyAudioWrite) -> Bool {
        writes += 1
        guard let next = snapshot.applying(change) else { return false }
        snapshot = next
        return true
    }
    func observe(_ snapshot: PrivacyAudioSnapshot?, changed: (@MainActor () -> Void)?) -> Bool {
        observations += 1; return true
    }
    func restoreLocal(_ original: LocalAudioState) -> Bool {
        restores += 1
        guard restoreSucceeds, original.matches(Self.local) else { return false }
        snapshot = Self.local; return true
    }
}

@MainActor private final class Fixture {
    let hal = HAL()
    let startup = NativeAudioStartup()
    let admission = SentryAdmission()
    var privacy: HostAudioPrivacy!
    var sentry: HostSentry!
    var saved: LocalAudioState?
    var durable = false
    var saveOK = true, persistOK = true
    var saves = 0, persists = 0, clears = 0, auths = 0, intents = 0
    var nativeStops = 0, relayStops = 0, inspections = 0, releases = 0
    var accepted = true, nativeMediaActive = false, relayMediaActive = false
    var unknownNative = false, unknownRelay = false, cannotStop = false
    var curtain = true, tap = true, surfaceOK = true
    var journalOK = true
    var authIDs: [UUID] = []
    var sentryStates: [String] = []
    var relayRequest: LocalAudioParticipantRequest?
    var authGate: Gate?, surfaceGate: Gate?, postIntentGate: Gate?
    var authHook: (() -> Void)?, intentHook: (() -> Void)?, surfaceHook: (() -> Void)?
    var events: [String] = []
    var finishedIntent = false
    var releasedWithoutProof = false

    init(latched: Bool = false, original: LocalAudioState? = nil, initialize: Bool = true) {
        saved = original; durable = latched
        privacy = HostAudioPrivacy(hal: hal, latched: latched, persist: { [unowned self] in
            persists += 1; if persistOK { durable = true }; return persistOK
        }, localState: original, saveLocal: { [unowned self] value in
            saves += 1
            guard saveOK else { return false }
            saved = value; durable = value != nil; return true
        }, clearLatch: { [unowned self] in
            clears += 1; durable = false; saved = nil; events.append("audio-journal-clear"); return true
        }, authenticateLocal: { [unowned self] id in
            auths += 1; authIDs.append(id); events.append("fresh-auth")
            authHook?()
            if let authGate { await authGate.wait() }
            return accepted
        }, nativeStartup: startup)
        if initialize { startup.construct { () } }
        registerRelay()
        privacy.revokeForLocalReturn = { [unowned self] in
            nativeStops += 1; events.append("native-drain")
            if finishedIntent, let postIntentGate { await postIntentGate.wait() }
            if !cannotStop { nativeMediaActive = false }
            return !nativeMediaActive && !cannotStop
        }
        privacy.inspectForLocalReturn = { [unowned self] in facts(native: true) }
        privacy.authenticatedLocalReturnWillCommit = { [unowned self] current in
            guard current() else { return false }
            intents += 1; events.append("intent-clear"); finishedIntent = true
            intentHook?()
            return current()
        }
        sentry = HostSentry(admission: admission, initiallyLatched: true, persistenceHealthy: true,
            persist: { [unowned self] state in
                sentryStates.append(state.rawValue); events.append("surface-journal-" + state.rawValue)
                return journalOK
            }, surfaces: .init(engage: { [unowned self] in curtain = true; tap = true; return true },
                verify: { [unowned self] in curtain && tap },
                release: { [unowned self] deadline, current in
                    releases += 1; events.append("surface-release-start")
                    if !current() || intents == 0 || nativeMediaActive || relayMediaActive ||
                        !startup.participants.isFenced || nativeStops < intents * 3 { releasedWithoutProof = true }
                    surfaceHook?()
                    if let surfaceGate {
                        guard await LocalAudioCompletion<Bool>.wait(until: deadline, operation: {
                            await surfaceGate.wait(); return !Task.isCancelled
                        }) == true else { return false }
                    }
                    await Task.yield()
                    guard surfaceOK, current(), ContinuousClock.now < deadline else { return false }
                    curtain = false; tap = false
                    events.append("surface-absent")
                    return !curtain && !tap && current()
                }, reason: { nil }, restoreCurtains: { [unowned self] in curtain = true; return true },
                released: { [unowned self] in !curtain && !tap }), prepareRelease: { true },
            localReturnUnavailableReason: { [unowned self] in privacy.localReturnUnavailableReason })
        privacy.localReturnActivityChanged = { [unowned self] in sentry.localReturnActivityChanged(privacy.localReturnInProgress) }
        privacy.localReturnDidComplete = { [unowned self] deadline, current, commitAudio in
            await sentry.completeAuthenticatedLocalReturn(until: deadline, current: current, commitAudio: commitAudio)
        }
        sentry.start()
    }
    func facts(native: Bool) -> LocalAudioParticipantFacts {
        if native ? unknownNative : unknownRelay { return .unknown }
        let inactive = !(native ? nativeMediaActive : relayMediaActive)
        return .init(admissionFenced: startup.participants.isFenced, startsSettled: inactive,
            mediaDetached: inactive, callbacksDrained: inactive, buffersEmpty: inactive, workersExited: inactive)
    }
    func registerRelay() {
        startup.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { [unowned self] request in
            relayStops += 1; relayRequest = request; events.append("relay-drain")
            if !cannotStop { relayMediaActive = false }
            let value = facts(native: false)
            return .init(request, state: value.quiescent ? .quiescent : .unknown, facts: value)
        }, inspect: { [unowned self] id in
            inspections += 1; events.append("relay-inspect")
            guard let request = relayRequest, request.operationId == id else { return nil }
            let value = facts(native: false)
            return .init(request, state: value.quiescent ? .quiescent : .unknown, facts: value)
        }, supportsForwarding: true, forwardingPrepare: { _ in nil }))
    }
    func reProtectSurface() {
        finishedIntent = false
        _ = sentry.activate()
    }
    var counts: [Int] { [hal.writes, hal.restores, saves, persists, clears] }
}

@main struct Checks {
    @MainActor static var failures: [String] = []
    @MainActor static var assertions = 0
    @MainActor static var traces: [[String: Any]] = []
    @MainActor static func check(_ condition: Bool, _ label: String) {
        assertions += 1
        if !condition { failures.append(label); print("ASSERTION FAILED: " + label) }
    }
    @MainActor private static func trace(_ name: String, _ f: Fixture) {
        traces.append(["case": name, "auths": f.auths, "intents": f.intents,
            "nativeStops": f.nativeStops, "relayStops": f.relayStops, "inspections": f.inspections,
            "releases": f.releases, "countsWriteRestoreSavePersistClear": f.counts,
            "latched": f.privacy.latched, "durable": f.durable, "curtain": f.curtain, "tap": f.tap,
            "events": f.events, "status": f.privacy.localReturnStatusReason ?? "none"])
    }
    @MainActor static func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }
    @MainActor private static func restored() async -> Fixture {
        let f = Fixture()
        check(f.privacy.armAndVerify(), "기존 234 경로는 실제 Model arm과 원본 저장 성공")
        let original = f.saved!
        let result = await f.privacy.requestLocalReturn()
        check(result && !f.privacy.latched && original.matches(f.hal.snapshot) && f.hal.restores == 1 &&
            f.clears == 1 && f.saves == 1 && !f.curtain && !f.tap,
            "첫 fresh auth는 원본 HAL 복원·표면 실부재·완료 저장까지 성공")
        check(!f.releasedWithoutProof && f.nativeStops == 3 && f.intents == 1,
            "첫 복귀도 post-intent native 재drain과 참여자 proof 유지")
        return f
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let f = await restored()
        f.reProtectSurface()
        let before = f.counts, snapshot = f.hal.snapshot, gate = Gate()
        f.surfaceGate = gate
        var secondFinished = false
        let second = Task { let result = await f.privacy.requestLocalReturn(); secondFinished = true; return result }
        await settle { gate.entered || secondFinished }
        check(gate.entered && f.auths == 2 && f.curtain && f.tap && f.counts == before,
            "표면만 재보호 후 새 인증은 HAL·원본·latch 쓰기 없이 실제 async 표면 ACK를 기다림")
        gate.released = true
        let secondResult = await second.value
        print("REPRO firstRestore=1 secondAccepted=\(secondResult) auths=\(f.auths) latched=\(f.privacy.latched) HALdelta=\(zip(before,f.counts).map { $1-$0 })")
        check(secondResult && f.auths == 2 && Set(f.authIDs).count == 2 && f.counts == before &&
            f.hal.snapshot == snapshot && !f.curtain && !f.tap && !f.privacy.latched && !f.releasedWithoutProof,
            "실제 Model 첫 audio 복원→표면 재보호→새 auth 로컬 복귀 성공, preserve HAL·원본·latch 쓰기0")
        check(f.nativeStops == 6 && f.relayStops == 2 && f.intents == 2 && f.inspections >= 4,
            "preserve도 새 native·relay fence/inspect·intent·post-intent 재drain 전체 수행")
        trace("restore-then-surface-only", f); f.privacy.stop()

        let fresh = Fixture(), freshCounts = [0,0,0,0,0]
        let initial = fresh.hal.snapshot
        check(await fresh.privacy.requestLocalReturn() && fresh.counts == freshCounts && fresh.hal.snapshot == initial &&
            fresh.auths == 1 && fresh.intents == 1 && fresh.nativeStops == 3 && !fresh.curtain && !fresh.tap,
            "초기 미적용 상태도 idle 위조 없이 전체 참여자 proof 후 현재 HAL 보존")
        trace("fresh-surface-only", fresh); fresh.privacy.stop()

        for mode in ["latched-missing", "latched-invalid", "residual-original", "arm-read", "arm-invalid", "arm-save", "persistence"] {
            let original = try LocalAudioState(HAL.local)
            var invalidObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            invalidObject["version"] = 99
            let invalid = try JSONDecoder().decode(LocalAudioState.self, from: JSONSerialization.data(withJSONObject: invalidObject))
            let bad = Fixture(latched: mode.hasPrefix("latched") || mode == "persistence",
                original: mode == "latched-invalid" ? invalid : mode == "residual-original" || mode == "persistence" ? original : nil)
            if mode == "arm-read" { bad.hal.readFails = true; check(!bad.privacy.armAndVerify(), "arm read 실패 재현"); bad.hal.readFails = false }
            if mode == "arm-invalid" {
                bad.hal.snapshot.input = 0; check(!bad.privacy.armAndVerify(), "arm 원본 검증 실패 재현"); bad.hal.snapshot = HAL.local
            }
            if mode == "arm-save" { bad.saveOK = false; check(!bad.privacy.armAndVerify(), "arm 저장 실패 재현"); bad.saveOK = true }
            if mode == "persistence" { bad.persistOK = false; check(!bad.privacy.armAndVerify(), "persist 실패 재현") }
            let counts = bad.counts
            check(!(await bad.privacy.requestLocalReturn()) && bad.curtain && bad.releases == 0 && bad.counts == counts,
                "\(mode)는 preserve로 우회하지 않고 HAL·원본·latch 변경0으로 거부")
            trace(mode, bad); bad.privacy.stop()
        }

        for mode in ["unknown-native", "unknown-relay", "missing-participant", "active-media", "auth-denied",
                     "generation", "membership", "cancel", "timeout", "readback-failure", "readback-change", "surface-failure", "surface-journal-failure"] {
            let bad = Fixture(), gate = Gate()
            if mode == "unknown-native" { bad.unknownNative = true }
            if mode == "unknown-relay" { bad.unknownRelay = true }
            if mode == "missing-participant" { bad.startup.participants.unregister(.relay) }
            if mode == "active-media" { bad.nativeMediaActive = true; bad.relayMediaActive = true; bad.cannotStop = true }
            if mode == "auth-denied" { bad.accepted = false }
            if mode == "readback-failure" { bad.intentHook = { bad.hal.readFails = true } }
            if mode == "readback-change" { bad.intentHook = { bad.hal.snapshot.devices[0].outputMuted = true } }
            if mode == "surface-failure" { bad.surfaceOK = false }
            if mode == "surface-journal-failure" { bad.journalOK = false }
            if ["generation", "membership", "cancel", "timeout"].contains(mode) { bad.surfaceGate = gate }
            let before = bad.counts
            var finished = false
            let task = Task {
                let result = await bad.privacy.requestLocalReturn(budgetMilliseconds: mode == "timeout" ? 60 : 2000)
                finished = true; return result
            }
            if bad.surfaceGate != nil {
                await settle { gate.entered || finished }
                if mode == "generation" { bad.privacy.stop() }
                if mode == "membership" { bad.registerRelay() }
                if mode == "cancel" { task.cancel() }
                if mode != "timeout" { gate.released = true }
            }
            let accepted = await task.value
            gate.released = true
            check(!accepted && bad.curtain && bad.counts == before && !bad.privacy.latched,
                "preserve \(mode)는 인증·proof·기한·표면 경계를 약화하지 않고 쓰기0 거부")
            trace(mode, bad); bad.privacy.stop()
        }

        let drain = Fixture(), drainGate = Gate()
        drain.postIntentGate = drainGate
        var drainFinished = false
        let draining = Task { let result = await drain.privacy.requestLocalReturn(); drainFinished = true; return result }
        await settle { drainGate.entered || drainFinished }
        check(drainGate.entered && drain.intents == 1 && drain.releases == 0 && drain.counts == [0,0,0,0,0],
            "preserve intent 후 native 종료가 남으면 HAL·표면·완료 저장 전에 기다림")
        drainGate.released = true
        check(await draining.value && !drain.curtain && drain.counts == [0,0,0,0,0],
            "preserve post-intent native 실제 종료 후에만 표면 해제")
        trace("post-intent-drain", drain); drain.privacy.stop()

        let report: [String: Any] = ["assertions": assertions, "failures": failures, "passed": failures.isEmpty,
            "cases": traces, "actualHALAuthHostUIAudioDeviceEffects": 0,
            "productionModelAndSentry": true, "freshAuthenticationPerRequest": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("surface-return.json"))
        print("surface-only assertions failed: \(failures.count); assertions: \(assertions); cases: \(traces.count); actual effects=0")
        if !failures.isEmpty { exit(1) }
    }
}
