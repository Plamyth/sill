import CoreAudio
import Foundation
import StreamProtocol

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL " + label + "\n", stderr); exit(1) }
    print("PASS " + label)
}

@main
struct HostAudioPrivacyChecks {
    @MainActor static func guardFor(_ fake: PrivacyFakeHAL, latched: Bool = false,
                                   persist: @escaping () -> Bool = { true }, localState: LocalAudioState? = nil) -> HostAudioPrivacy {
        HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: fake.operations), latched: latched, persist: persist, localState: localState)
    }

    @MainActor static func main() async {
        let untouched = PrivacyFakeHAL(), unarmed = guardFor(untouched)
        expect(!unarmed.verify() && untouched.reads == 0 && untouched.writes.isEmpty, "legacy guard has no automatic HAL effects")
        let nilOwner = SillVirtualMicrophoneOwner(ops: untouched.microphoneOperations)
        expect(grant(nilOwner) == nil && untouched.reads == 0, "owner without privacy never discovers native or injected hardware")
        unarmed.stop()

        let fake = PrivacyFakeHAL()
        var durable = false
        fake.beforeSet = { expect(durable, "latch saved before HAL setter") }
        let privacy = guardFor(fake, persist: { durable = true; return true })
        expect(privacy.armAndVerify() && durable && privacy.latched, "arm latches and verifies")
        expect(fake.writes == [.mute(10, .input), .mute(10, .output), .select(.input, 20),
                               .select(.output, 30), .select(.systemOutput, 30)], "only built-in mutes and three virtual defaults written")
        expect(privacy.state == AudioPrivacyState(version: 2, protected: true) && privacy.verify(), "version two ready is actual endpoint readback")
        let writes = fake.writes
        expect(privacy.armAndVerify() && fake.writes == writes, "already safe defaults require no writes")
        privacy.stop()
        expect(fake.writes == writes && durable, "shutdown preserves mutes defaults and durable latch")
        let relaunched = guardFor(fake, latched: durable, localState: try? LocalAudioState(untouched.snapshot))
        expect(relaunched.reconcile() && fake.writes == writes, "persisted latch protects before any new connection")
        relaunched.stop()

        let stoppedFake = PrivacyFakeHAL(), stopped = guardFor(stoppedFake)
        expect(stopped.armAndVerify(), "late callback fixture starts protected")
        stoppedFake.snapshot.input = 10
        stoppedFake.fire(kAudioHardwarePropertyDefaultInputDevice)
        stopped.stop()
        let stoppedWrites = stoppedFake.writes
        let stoppedReads = stoppedFake.reads
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(stoppedFake.writes == stoppedWrites && stoppedFake.reads == stoppedReads &&
               stoppedFake.listenerCount == 0 && !stopped.state.protected,
               "queued callback after stop cannot rearm observers or write hardware")
        expect(stopped.reconcile() && stopped.verify(), "explicit reconciliation resumes stopped observation")
        stopped.stop()
        expect(stopped.armAndVerify() && stopped.verify(), "explicit arm resumes stopped observation")
        stopped.stop()

        let pendingFake = PrivacyFakeHAL(), pendingPrivacy = guardFor(pendingFake)
        expect(pendingPrivacy.armAndVerify(), "pending repair fixture starts protected")
        pendingFake.snapshot.input = 10
        expect(!pendingPrivacy.verify(), "readback mismatch schedules a pending repair")
        pendingPrivacy.stop()
        let pendingReads = pendingFake.reads, pendingWrites = pendingFake.writes
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(pendingFake.reads == pendingReads && pendingFake.writes == pendingWrites &&
               pendingFake.listenerCount == 0 && !pendingPrivacy.state.protected,
               "stop cancels an already scheduled repair without restoring hardware")

        let observationFake = PrivacyFakeHAL()
        let observationHAL = CoreAudioPrivacyHAL(ops: observationFake.operations)
        var oldEvents = 0, newEvents = 0
        expect(observationHAL.observe(nil, changed: { oldEvents += 1 }), "observation generation fixture installed")
        observationFake.fire(kAudioHardwarePropertyDevices, object: AudioObjectID(kAudioObjectSystemObject))
        expect(observationHAL.observe(nil, changed: nil), "observation generation fixture stopped")
        expect(observationHAL.observe(nil, changed: { newEvents += 1 }), "observation generation fixture restarted")
        observationFake.fire(kAudioHardwarePropertyDevices, object: AudioObjectID(kAudioObjectSystemObject))
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(oldEvents == 0 && newEvents == 1, "queued old observation cannot enter a restarted lifecycle")
        expect(observationHAL.observe(nil, changed: { newEvents += 1 }), "observation replacement fixture installed")
        observationFake.fire(kAudioHardwarePropertyDevices, object: AudioObjectID(kAudioObjectSystemObject))
        expect(observationHAL.observe(nil, changed: { newEvents += 1 }), "observation replaced before callback delivery")
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(newEvents == 1, "replaced observation discards its queued callbacks")
        expect(observationHAL.observe(nil, changed: nil), "observation generation fixture cleaned up")

        for index in 1...5 {
            let failed = PrivacyFakeHAL(); failed.failSetter = index
            let guarder = guardFor(failed)
            expect(!guarder.armAndVerify() && !guarder.state.protected && failed.writes.count == index,
                   "setter failure refuses readiness at operation \(index)")
            guarder.stop()
            let lying = PrivacyFakeHAL(); lying.ignoreSetter = index
            let noReadback = guardFor(lying)
            expect(!noReadback.armAndVerify() && !noReadback.state.protected,
                   "successful setter without matching readback rejected at operation \(index)")
            noReadback.stop()
        }
        for selector in [kAudioDevicePropertyMute, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            let failed = PrivacyFakeHAL(); failed.missingSelector = selector
            let guarder = guardFor(failed)
            expect(!guarder.armAndVerify() && !guarder.state.protected, "missing mute/default readback refuses admission \(selector)")
            guarder.stop()
        }
        for mode in 0..<8 {
            let bad = PrivacyFakeHAL()
            let target = bad.snapshot.devices[1]
            switch mode {
            case 0: bad.wrongPlugin = true
            case 1: bad.wrongResolution = true
            case 2:
                bad.snapshot.devices[1] = PrivacyAudioDevice(id: 20, uid: "lookalike", transport: .virtual,
                    plugin: target.plugin, inputChannels: 2, outputChannels: 2)
            case 3:
                bad.snapshot.devices[1] = PrivacyAudioDevice(id: 20, uid: target.uid, transport: .other,
                    plugin: target.plugin, inputChannels: 2, outputChannels: 2)
            case 4:
                bad.snapshot.devices.append(PrivacyAudioDevice(id: 21, uid: "duplicate", transport: .virtual,
                    plugin: target.plugin, inputChannels: 2, outputChannels: 2))
            case 5: bad.snapshot.devices.removeLast()
            case 6: bad.writable = false
            default: bad.listenerFailure = true
            }
            let guarder = guardFor(bad)
            expect(!guarder.armAndVerify() && !guarder.state.protected && bad.writes.isEmpty,
                   "identity transport unique plugin mute listener failure \(mode)")
            guarder.stop()
        }
        let unsaved = PrivacyFakeHAL(), noPersistence = guardFor(unsaved, persist: { false })
        expect(!noPersistence.armAndVerify() && !noPersistence.latched && unsaved.reads == 0,
               "persistence failure stops before native boundary")
        noPersistence.stop()
        await localReturnChecks()
        await adversarialLocalReturnChecks()
        await serverDrainChecks()
        await nativeStartupChecks()
        await endpointChecks()
        await eventChecks()
        await ownerChecks()
        wireChecks()
        let boundaryHAL = PrivacyFakeHAL(), boundaryPrivacy = guardFor(boundaryHAL)
        expect(boundaryPrivacy.armAndVerify(), "boundary fixture armed")
        await coordinatorChecks(boundaryPrivacy)
        boundaryPrivacy.stop()
        print("Host audio privacy: all injected checks passed; no native hardware calls")
    }

    @MainActor static func endpointChecks() async {
        for scope in [PrivacyAudioScope.input, .output] {
            let direction = scope == .input ? "입력" : "출력"
            for mode in 0..<3 {
                let fake = PrivacyFakeHAL()
                fake.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
                    plugin: nil, inputChannels: 32, outputChannels: 32, inputMuted: true, outputMuted: true))
                switch mode {
                case 0: fake.readOnlyMutes = [.mute(50, scope)]
                case 1: fake.failedMuteReads = [.mute(50, scope)]
                default:
                    if scope == .input { fake.snapshot.devices[3].inputMuted = nil }
                    else { fake.snapshot.devices[3].outputMuted = nil }
                }
                let privacy = guardFor(fake)
                expect(!privacy.armAndVerify() && !privacy.state.protected && fake.writes.isEmpty &&
                       privacy.state.reason?.contains("external-USB") == true &&
                       privacy.state.reason?.contains(direction) == true,
                       "external \(direction) missing readback or writable master refuses privacy \(mode)")
                privacy.stop()
            }

            let fake = PrivacyFakeHAL()
            fake.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
                plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
            let hal = CoreAudioPrivacyHAL(ops: fake.operations)
            let original = try! hal.read()
            expect((try? original.plan().contains(.mute(50, scope))) == true,
                   "external \(direction) master is included in allowed writes")
            fake.readOnlyMutes = [.mute(50, scope)]
            expect(!hal.write(.mute(50, scope)) && fake.writes.isEmpty,
                   "stale external \(direction) command rejected after master becomes read-only")
            fake.readOnlyMutes = []; fake.failedMuteReads = [.mute(50, scope)]
            expect(!hal.write(.mute(50, scope)) && fake.writes.isEmpty,
                   "stale external \(direction) command rejected after readback loss")
            fake.failedMuteReads = []
            fake.snapshot.devices[3] = PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
                plugin: nil, inputChannels: scope == .input ? 0 : 2, outputChannels: scope == .output ? 0 : 2,
                inputMuted: false, outputMuted: false)
            expect(!hal.write(.mute(50, scope)) && fake.writes.isEmpty,
                   "stale external \(direction) command rejected after direction disappears")

            let observed = PrivacyFakeHAL()
            observed.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
                plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
            observed.rejectedMuteListener = .mute(50, scope)
            let unobserved = guardFor(observed)
            expect(!unobserved.armAndVerify() && !unobserved.state.protected && observed.writes.isEmpty,
                   "external \(direction) mute listener installation is mandatory")
            unobserved.stop()
        }

        let fake = PrivacyFakeHAL()
        fake.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
            plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
        let privacy = guardFor(fake)
        var states: [AudioPrivacyState] = []
        privacy.changed = { states.append($0) }
        expect(privacy.armAndVerify() && fake.snapshot.devices[3].inputMuted == true &&
               fake.snapshot.devices[3].outputMuted == true, "external masters require successful setter readback")
        for scope in [PrivacyAudioScope.input, .output] {
            let halScope = scope == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
            expect(fake.isListening(50, kAudioDevicePropertyMute, halScope) &&
                   fake.isListening(50, kAudioDevicePropertyStreamConfiguration, halScope),
                   "external \(scope) mute and stream configuration observed")
            let count = states.count
            if scope == .input { fake.snapshot.devices[3].inputMuted = false }
            else { fake.snapshot.devices[3].outputMuted = false }
            fake.fire(kAudioDevicePropertyMute, object: 50)
            try? await Task.sleep(nanoseconds: 200_000_000)
            expect(states.dropFirst(count).contains(where: { !$0.protected }) && privacy.state.protected &&
                   fake.snapshot.devices[3].inputMuted == true && fake.snapshot.devices[3].outputMuted == true,
                   "external \(scope) unmute event revokes then remutes through readback")
        }
        fake.failedMuteReads = [.mute(50, .output)]
        expect(!privacy.verify() && !privacy.state.protected && privacy.state.reason?.contains("external-USB") == true,
               "external readback loss revokes existing protected state")
        privacy.stop()

        let generations = PrivacyFakeHAL()
        generations.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
            plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: true, outputMuted: true))
        let hal = CoreAudioPrivacyHAL(ops: generations.operations)
        let snapshot = try! hal.read()
        var oldEvents = 0, newEvents = 0
        expect(hal.observe(snapshot, changed: { oldEvents += 1 }), "external observation generation installed")
        generations.fire(kAudioDevicePropertyMute, object: 50)
        expect(hal.observe(snapshot, changed: { newEvents += 1 }), "external observation generation replaced")
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(oldEvents == 0 && newEvents == 0, "queued external callback cannot cross observation generations")
        generations.fire(kAudioDevicePropertyMute, object: 50)
        try? await Task.sleep(nanoseconds: 150_000_000)
        expect(newEvents == 2, "current external input and output listeners deliver changes")
        expect(hal.observe(nil, changed: nil), "external observation generation cleaned up")

        for index in [3, 4] {
            let lying = PrivacyFakeHAL()
            lying.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "external-USB", transport: .other,
                plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
            lying.ignoreSetter = index
            let noReadback = guardFor(lying)
            expect(!noReadback.armAndVerify() && !noReadback.state.protected && lying.writes.count == index,
                   "external master setter without readback refuses privacy at operation \(index)")
            noReadback.stop()
        }
    }

    @MainActor static func eventChecks() async {
        let fake = PrivacyFakeHAL(), privacy = guardFor(fake)
        var states: [AudioPrivacyState] = []
        privacy.changed = { states.append($0) }
        expect(privacy.armAndVerify(), "event fixture ready")
        fake.snapshot.systemOutput = 10
        fake.fire(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(states.contains(where: { !$0.protected }) && privacy.verify() && fake.snapshot.systemOutput == 30,
               "default-change listener revokes before bounded reconciliation")
        let count = fake.writes.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(fake.writes.count == count, "reconciliation does not busy-loop")
        let virtual = fake.snapshot.devices.removeLast()
        fake.fire(kAudioHardwarePropertyDevices)
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(!privacy.verify(), "virtual device hot-unplug revokes readiness")
        fake.snapshot.devices.append(virtual)
        fake.snapshot.devices[0].inputMuted = false
        fake.fire(kAudioHardwarePropertyDevices)
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(privacy.verify() && fake.snapshot.devices[0].inputMuted == true, "hotplug revalidates devices and remutes built-in input")
        fake.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "DN32-LIVE", transport: .other,
            plugin: nil, inputChannels: 32, outputChannels: 32))
        expect(!privacy.reconcile() && !privacy.state.protected,
               "DN32 without any physical mute refuses complete privacy")
        fake.snapshot.devices[fake.snapshot.devices.count - 1].inputMuted = false
        fake.snapshot.devices[fake.snapshot.devices.count - 1].outputMuted = false
        expect(privacy.reconcile() && fake.writes.contains(.mute(50, .input)) &&
               fake.writes.contains(.mute(50, .output)), "writable USB input and output are both muted")
        fake.snapshot.devices[fake.snapshot.devices.count - 1].outputMuted = false
        fake.fire(kAudioDevicePropertyMute, object: 50)
        try? await Task.sleep(nanoseconds: 200_000_000)
        expect(privacy.verify() && fake.snapshot.devices.last?.outputMuted == true,
               "external USB unmute event remutes before readiness")
        fake.snapshot.devices.append(PrivacyAudioDevice(id: 60, uid: "HDMI", transport: .other,
            plugin: nil, inputChannels: 0, outputChannels: 2))
        expect(!privacy.reconcile() && !privacy.state.protected,
               "HDMI with no mute is not silently exempted")
        fake.snapshot.devices[fake.snapshot.devices.count - 1].outputMuted = false
        fake.emptyInputConfiguration = true
        expect(privacy.reconcile(), "HDMI zero-byte input configuration is not an overall read failure")
        fake.emptyInputConfiguration = false; fake.zeroInputBuffers = true
        expect(privacy.reconcile(), "HDMI zero-input-buffer list is accepted")
        fake.snapshot.devices.append(PrivacyAudioDevice(id: 70, uid: "unverified-aggregate", transport: .virtual,
            plugin: nil, inputChannels: 2, outputChannels: 2))
        expect(!privacy.reconcile() && !privacy.state.protected,
               "unknown virtual or aggregate routes cannot bypass endpoint coverage")
        fake.snapshot.devices[fake.snapshot.devices.count - 1].inputMuted = false
        fake.snapshot.devices[fake.snapshot.devices.count - 1].outputMuted = false
        expect(privacy.reconcile() && fake.writes.contains(.mute(70, .input)) &&
               fake.writes.contains(.mute(70, .output)), "other virtual endpoints require both master mutes")
        privacy.stop()
    }

    @MainActor static func localReturnChecks() async {
        let fake = PrivacyFakeHAL()
        let before = fake.snapshot
        var saved: LocalAudioState?
        var latch = false
        var accepted = false
        var authCalls = 0
        let privacy = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: fake.operations), persist: { latch = true; return true },
            saveLocal: { saved = $0; return true }, clearLatch: { latch = false; return true },
            authenticateLocal: { authCalls += 1; return accepted })
        privacy.revokeForLocalReturn = { true }
        expect(privacy.armAndVerify() && saved == (try? LocalAudioState(before)), "original local UIDs and mutes saved before protection")
        let original = saved
        expect(privacy.armAndVerify() && saved == original, "repeated remote admission preserves original local state")
        let mutations = fake.writes.count
        let denied = await privacy.requestLocalReturn()
        expect(!denied && fake.writes.count == mutations && latch, "denied authentication never restores devices")
        accepted = true
        var revokedBeforeRestore = false
        privacy.changed = { if !$0.protected { revokedBeforeRestore = true } }
        fake.beforeSet = { expect(revokedBeforeRestore, "remote authority revoked before any local restore setter") }
        let restored = await privacy.requestLocalReturn()
        expect(restored && fake.snapshot == before && !latch && !privacy.latched && saved == nil,
               "authenticated return restores exact local UIDs and mutes and clears durable latch")
        let restoredWrites = fake.writes.count
        expect(!privacy.verify() && fake.writes.count == restoredWrites, "connected remote retry cannot revive audio after local return")
        let alreadyLocal = await privacy.requestLocalReturn()
        expect(!alreadyLocal && authCalls == 2, "already local mode does not ask for authentication again")
        fake.beforeSet = nil
        expect(privacy.armAndVerify() && saved == original, "a fresh remote admission captures the restored local state")
        privacy.stop()

        let staleFake = PrivacyFakeHAL()
        var completion: CheckedContinuation<Bool, Never>?
        let stale = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: staleFake.operations), clearLatch: { true },
            authenticateLocal: { await withCheckedContinuation { completion = $0 } })
        stale.revokeForLocalReturn = { true }
        expect(stale.armAndVerify(), "stale auth fixture armed")
        let task = Task { @MainActor in await stale.requestLocalReturn() }
        for _ in 0..<20 { if completion != nil { break }; await Task.yield() }
        expect(completion != nil, "pending native authentication reached its boundary")
        expect(!stale.armAndVerify(), "new remote admission invalidates the ticket without readiness during local return")
        let staleWrites = staleFake.writes.count
        completion?.resume(returning: true)
        let staleResult = await task.value
        expect(!staleResult && staleFake.writes.count == staleWrites && stale.latched,
               "late successful authentication cannot restore a superseded session")
        stale.stop()

        let missingFake = PrivacyFakeHAL()
        let missing = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: missingFake.operations), clearLatch: { true },
            authenticateLocal: { true })
        missing.revokeForLocalReturn = { true }
        expect(missing.armAndVerify(), "missing original fixture armed")
        missingFake.snapshot.devices.removeFirst()
        let missingWrites = missingFake.writes.count
        let missingResult = await missing.requestLocalReturn()
        expect(!missingResult && missingFake.writes.count == missingWrites && missing.latched,
               "missing original UID refuses restoration without choosing a fallback")
        missing.stop()
    }

    @MainActor static func adversarialLocalReturnChecks() async {
        let unsupported = PrivacyFakeHAL()
        unsupported.snapshot.devices.append(PrivacyAudioDevice(id: 50, uid: "DN32-LIVE", transport: .other,
            plugin: nil, inputChannels: 32, outputChannels: 32))
        let unchanged = unsupported.snapshot
        let unsupportedPrivacy = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: unsupported.operations),
            clearLatch: { true }, authenticateLocal: { true })
        var stopped = false
        unsupportedPrivacy.revokeForLocalReturn = { stopped = true; return true }
        expect(!unsupportedPrivacy.armAndVerify() && unsupported.writes.isEmpty,
               "unsupported physical endpoint refuses protection before mutation")
        let unchangedReturn = await unsupportedPrivacy.requestLocalReturn()
        expect(unchangedReturn && stopped && !unsupportedPrivacy.latched && unsupported.writes.isEmpty && unsupported.snapshot == unchanged,
               "authenticated return clears failed protection when originals are already unchanged")
        unsupportedPrivacy.stop()
        let capture = PrivacyFakeHAL()
        let noJournal = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: capture.operations), saveLocal: { _ in false })
        expect(!noJournal.armAndVerify() && noJournal.latched && capture.writes.isEmpty, "failed first journal capture cannot mutate hardware")
        expect(!noJournal.armAndVerify() && !noJournal.reconcile() && capture.writes.isEmpty, "retry cannot snapshot protected state or bypass missing journal")
        noJournal.stop()
        let restart = guardFor(capture, latched: true)
        expect(!restart.reconcile() && !restart.armAndVerify() && capture.writes.isEmpty, "restart with missing original journal refuses all writes")
        restart.stop()

        for mutate in [0, 1, 2, 3] {
            let fake = PrivacyFakeHAL()
            let original = try! LocalAudioState(fake.snapshot)
            fake.safe()
            let restoring = CoreAudioPrivacyHAL(ops: fake.operations)
            fake.afterSet = {
                if mutate == 0 {
                    let old = fake.snapshot.devices[0]
                    fake.snapshot.devices[0] = PrivacyAudioDevice(id: old.id, uid: "reused-ID", transport: old.transport,
                        plugin: old.plugin, inputChannels: old.inputChannels, outputChannels: old.outputChannels,
                        inputMuted: old.inputMuted, outputMuted: old.outputMuted)
                } else if mutate == 1 { fake.snapshot.systemOutput = 10 }
                else if mutate == 3 {
                    let old = fake.snapshot.devices[0]
                    fake.snapshot.devices[0] = PrivacyAudioDevice(id: old.id, uid: old.uid, transport: .other,
                        plugin: old.plugin, inputChannels: old.inputChannels, outputChannels: old.outputChannels,
                        inputMuted: old.inputMuted, outputMuted: old.outputMuted)
                } else { fake.snapshot.devices.append(PrivacyAudioDevice(id: 40, uid: "hotplug", transport: .other,
                    plugin: nil, inputChannels: 0, outputChannels: 2, inputMuted: nil, outputMuted: true)) }
            }
            expect(!restoring.restoreLocal(original) && fake.writes.count == 1, "unexpected setter transition stops before next UID setter \(mutate)")
        }

        let fake = PrivacyFakeHAL()
        var journal: LocalAudioState?
        var allowSave = true
        let privacy = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: fake.operations),
            saveLocal: { if allowSave { journal = $0 }; return allowSave }, clearLatch: { true }, authenticateLocal: { true })
        privacy.revokeForLocalReturn = { true }
        expect(privacy.armAndVerify(), "cleanup interruption fixture armed")
        allowSave = false
        let returned = await privacy.requestLocalReturn()
        expect(returned && journal != nil, "completed local return tolerates interrupted legacy cleanup")
        fake.snapshot.devices[0].inputMuted = true
        let newOriginal = try! LocalAudioState(fake.snapshot)
        allowSave = true
        expect(privacy.armAndVerify() && journal == newOriginal, "fresh unlatched session replaces stale completed journal with current user mute")
        privacy.stop()

        let observing = PrivacyFakeHAL()
        let observer = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: observing.operations), clearLatch: { true }, authenticateLocal: { true })
        observer.revokeForLocalReturn = { true }
        expect(observer.armAndVerify(), "observer removal fixture armed")
        observing.removalFailure = true
        let removed = await observer.requestLocalReturn()
        expect(!removed && !observer.verify() && !observer.state.protected && observer.latched, "failed removal cannot advertise an invalidated observer as healthy")
        observing.removalFailure = false
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(observer.verify(), "bounded listener repair recovers observation while preserving latch")
        observer.stop()

        for rollbackSucceeds in [false, true] {
            let device = PrivacyFakeHAL()
            var data: Data?
            var syncOK = true
            let store = LocalAudioJournal(data: nil, store: { data = $0 }, load: { data }, synchronize: { syncOK })
            let guarder = HostAudioPrivacy(localReturnCoverage: .verifiedAllParticipants, hal: CoreAudioPrivacyHAL(ops: device.operations),
                persist: { store.write(latched: true, original: store.original) },
                saveLocal: { store.write(latched: $0 != nil, original: $0) },
                clearLatch: {
                    syncOK = false
                    let result = store.write(latched: false, original: nil)
                    syncOK = rollbackSucceeds
                    return result
                }, authenticateLocal: { true })
            guarder.revokeForLocalReturn = { true }
            expect(guarder.armAndVerify(), "durable clear failure fixture armed")
            let result = await guarder.requestLocalReturn()
            expect(!result && guarder.latched, "failed clear never completes local return")
            if rollbackSucceeds {
                let persisted = try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: data!)
                expect(persisted.latched && persisted.original?.isValid == true && guarder.verify(), "failed clear reasserts durable original envelope before protection is ready")
            } else {
                let writes = device.writes.count
                expect(!guarder.verify() && !guarder.reconcile() && device.writes.count == writes && !guarder.state.protected,
                    "failed durable reassertion stays faulted without repair writes or readiness")
            }
            guarder.stop()
        }
        let malformed = LocalAudioJournal(data: Data("broken".utf8), store: { _ in }, load: { nil }, synchronize: { true })
        expect(malformed.latched && malformed.original == nil, "malformed durable envelope loads as latched fault")
    }

    @MainActor static func grant(_ owner: SillVirtualMicrophoneOwner) -> HostLocalOwnerGrant? {
        owner.microphoneGrant(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), fingerprint: Data([1]))
    }

    @MainActor static func ownerChecks() async {
        let fake = PrivacyFakeHAL(); fake.safe()
        let privacy = guardFor(fake)
        expect(privacy.armAndVerify() && fake.writes.isEmpty, "microphone starts with BlackHole2 already default")
        let owner = SillVirtualMicrophoneOwner(ops: fake.microphoneOperations, privacy: privacy)
        let first = grant(owner)!, firstRender = MicrophoneRenderBuffer(grant: first)
        let old = await owner.prepareMicrophone(grant: first, render: firstRender)
        expect(old.error == nil && old.resource != nil, "already selected BlackHole input admits a new lease")
        let busy = await owner.prepareMicrophone(grant: first, render: firstRender)
        expect(busy.resource == nil && busy.error != nil, "active lease prevents second microphone acquisition")
        owner.restoreMicrophoneForExit()
        let second = grant(owner)!, render = MicrophoneRenderBuffer(grant: second)
        let current = await owner.prepareMicrophone(grant: second, render: render)
        expect(current.error == nil && current.resource != nil, "new lease can replace retired exit lease")
        _ = await old.resource?.close()
        let stillBusy = await owner.prepareMicrophone(grant: second, render: render)
        expect(stillBusy.resource == nil && stillBusy.error != nil, "stale lease cleanup cannot release a newer lease")
        _ = await current.resource?.close()
        fake.snapshot.input = 10
        expect(grant(owner) == nil, "microphone advertisement suppressed after readback loss")
        owner.restoreMicrophoneForExit(); privacy.stop()
        expect(fake.writes.isEmpty && fake.snapshot.input == 10, "cleanup never restores or changes physical defaults")
    }

    @MainActor static func wireChecks() {
        let status = AudioPrivacyState(version: 2, protected: true)
        expect(status.version == 2 && Wire.decode(AudioPrivacyState.self, from: Wire.encode(status)) == status,
               "version two privacy status roundtrips")
        let legacy = AudioPrivacyState(protected: true)
        expect(Wire.decode(AudioPrivacyState.self, from: Wire.encode(legacy))?.version == 1 && legacy != status,
               "legacy built-in-only status retains version one without upgrading coverage")
        let old = WindowList(macName: "시험", windows: [], active: .none)
        expect(Wire.decode(WindowList.self, from: Wire.encode(old))?.audioPrivacy == nil, "old catalog decodes with absent privacy field")
        let new = WindowList(macName: "시험", windows: [], active: .none, audioPrivacy: status)
        expect(Wire.decode(WindowList.self, from: Wire.encode(new))?.audioPrivacy == status, "optional version two catalog status")
    }
}
