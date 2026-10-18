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
                                   persist: @escaping () -> Bool = { true }) -> HostAudioPrivacy {
        HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: fake.operations), latched: latched, persist: persist)
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
        expect(privacy.state == AudioPrivacyState(protected: true) && privacy.verify(), "version one ready is actual readback")
        let writes = fake.writes
        expect(privacy.armAndVerify() && fake.writes == writes, "already safe defaults require no writes")
        privacy.stop()
        expect(fake.writes == writes && durable, "shutdown preserves mutes defaults and durable latch")
        let relaunched = guardFor(fake, latched: durable)
        expect(relaunched.reconcile() && fake.writes == writes, "persisted latch protects before any new connection")
        relaunched.stop()

        let stoppedFake = PrivacyFakeHAL(), stopped = guardFor(stoppedFake)
        expect(stopped.armAndVerify(), "late callback fixture starts protected")
        stoppedFake.snapshot.input = 10
        stoppedFake.fire(kAudioHardwarePropertyDefaultInputDevice)
        stopped.stop()
        let stoppedWrites = stoppedFake.writes
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(stoppedFake.writes == stoppedWrites && !stopped.state.protected,
               "queued callback after stop cannot rearm observers or write hardware")

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
        await eventChecks()
        await ownerChecks()
        wireChecks()
        let boundaryHAL = PrivacyFakeHAL(), boundaryPrivacy = guardFor(boundaryHAL)
        expect(boundaryPrivacy.armAndVerify(), "boundary fixture armed")
        await coordinatorChecks(boundaryPrivacy)
        boundaryPrivacy.stop()
        print("Host audio privacy: all injected checks passed; no native hardware calls")
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
        expect(privacy.reconcile(), "external direct-device silence is outside protected built-in scope")
        fake.snapshot.devices.append(PrivacyAudioDevice(id: 60, uid: "HDMI", transport: .other,
            plugin: nil, inputChannels: 0, outputChannels: 2))
        fake.emptyInputConfiguration = true
        expect(privacy.reconcile(), "HDMI zero-byte input configuration is not an overall read failure")
        fake.emptyInputConfiguration = false; fake.zeroInputBuffers = true
        expect(privacy.reconcile(), "HDMI zero-input-buffer list is accepted")
        privacy.stop()
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
        let status = AudioPrivacyState(protected: true)
        expect(Wire.decode(AudioPrivacyState.self, from: Wire.encode(status)) == status, "privacy status roundtrips")
        let old = WindowList(macName: "시험", windows: [], active: .none)
        expect(Wire.decode(WindowList.self, from: Wire.encode(old))?.audioPrivacy == nil, "old catalog decodes with absent privacy field")
        let new = WindowList(macName: "시험", windows: [], active: .none, audioPrivacy: status)
        expect(Wire.decode(WindowList.self, from: Wire.encode(new))?.audioPrivacy == status, "optional version one catalog status")
    }
}
