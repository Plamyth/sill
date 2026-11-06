import Foundation
import StreamProtocol

func readablePhysicalEndpointsProtected(_ snapshot: PrivacyAudioSnapshot) -> Bool {
    let physical = Set(snapshot.devices.filter { ($0.transport == .builtIn || $0.transport == .other) && $0.plugin == nil }.map(\.uid))
    let coverage = snapshot.coverage.filter { physical.contains($0.uid) }
    return !coverage.isEmpty && coverage.allSatisfy(\.protected)
}

@MainActor
func physicalAbortCompensationChecks() async {
    var compensated = true
    for fault in ["listener", "virtual-unplug"] {
        let f = JournalReturnFixture()
        var admitted = true
        expect(f.privacy.armAndVerify(), "물리 보상 \(fault) fixture 보호")
        let writes = f.hal.writes
        f.hal.afterRestore = {
            admitted = false
            if fault == "listener" { f.hal.observationsOK = false }
            else { f.hal.snapshot.devices.removeAll { $0.id == 20 } }
        }
        let result = await f.privacy.requestNormalDisconnectReturn { admitted }
        let physical = readablePhysicalEndpointsProtected(f.hal.snapshot)
        print("PHYSICAL_ABORT_REPRO fault=\(fault) returned=\(result) compensationWrites=\(f.hal.writes - writes) physicalProtected=\(physical) inputMuted=\(f.hal.snapshot.devices[0].inputMuted == true) outputMuted=\(f.hal.snapshot.devices[0].outputMuted == true)")
        compensated = compensated && !result && physical && f.hal.writes > writes && !f.privacy.forwardingHealth()
        f.privacy.stop()
    }
    expect(compensated, "observer·BlackHole 장애가 남은 물리 보호 보상 쓰기를 막지 않음")
    #if PHYSICAL_COMPENSATION
    await nativePhysicalAbortChecks()
    #endif
}

#if PHYSICAL_COMPENSATION
@MainActor
private func nativePhysicalAbortChecks() async {
    for manual in [false, true] {
        for fault in ["listener", "virtual-unplug", "setter", "unreadable-device", "builtin-unplug", "streams"] {
            let fake = PrivacyFakeHAL(), participant = ReturnFixture()
            fake.snapshot.devices.append(.init(id: 80, uid: "external-80", transport: .other, plugin: nil,
                inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
            fake.snapshot.devices.append(.init(id: 90, uid: "external-90", transport: .other, plugin: nil,
                inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false))
            if fault == "streams" {
                let format = PrivacyAudioStream.Format(sampleRate: 48_000, formatID: 0x6c70636d, flags: 12,
                    bytesPerPacket: 8, framesPerPacket: 1, bytesPerFrame: 8, channels: 2, bitsPerChannel: 32, reserved: 0)
                fake.snapshot.devices[3] = .init(id: 80, uid: "external-80", transport: .other, plugin: nil,
                    inputChannels: 2, outputChannels: 2, streams: [
                        .init(id: 81, ownerID: 80, direction: .input, startingChannel: 1, virtualFormat: format, physicalFormat: format, active: true, activeSettable: true),
                        .init(id: 82, ownerID: 80, direction: .output, startingChannel: 1, virtualFormat: format, physicalFormat: format, active: true, activeSettable: true)])
            }
            let original = try! LocalAudioState(fake.snapshot)
            let hal = CoreAudioPrivacyHAL(ops: fake.operations)
            let privacy = HostAudioPrivacy(hal: hal, clearLatch: { true }, authenticateLocal: { _ in manual }, nativeStartup: participant.startup)
            privacy.revokeForLocalReturn = { true }
            privacy.inspectForLocalReturn = { participant.facts }
            privacy.authenticatedLocalReturnWillCommit = { admission in admission() }
            privacy.localReturnDidComplete = { _, _, _ in false }
            expect(privacy.armAndVerify(), "native \(manual)/\(fault) fixture 보호")
            var injected = false, writesAtAbort = 0
            var defaultsAtAbort: [UInt32] = []
            fake.afterSet = {
                guard !injected, original.matches(fake.snapshot) else { return }
                injected = true;writesAtAbort = fake.writes.count
                defaultsAtAbort = [fake.snapshot.input, fake.snapshot.output, fake.snapshot.systemOutput]
                switch fault {
                case "listener": fake.listenerFailure = true
                case "virtual-unplug": fake.snapshot.devices.removeAll { $0.id == 20 }
                case "setter": fake.failSetter = fake.writes.count + 1
                case "unreadable-device": fake.snapshot.devices[3] = .init(id: 80, uid: "", transport: .other, plugin: nil, inputChannels: 2, outputChannels: 2, inputMuted: false, outputMuted: false)
                case "builtin-unplug": fake.snapshot.devices.removeAll { $0.id == 10 }
                default: fake.snapshot.devices.removeAll { $0.id == 20 };fake.failSetter = fake.writes.count + 3
                }
            }
            let result = manual ? await privacy.requestLocalReturn() : await privacy.requestNormalDisconnectReturn { !injected }
            expect(injected && !result && privacy.latched && !privacy.state.protected && !privacy.forwardingHealth(),
                   "native \(manual)/\(fault) abort 뒤 새 grant 거절")
            let remaining = fake.snapshot.devices.first { $0.id == 90 }!
            expect(remaining.inputMuted == true && remaining.outputMuted == true,
                   "native \(manual)/\(fault) 한 장치 실패와 무관하게 다음 물리 장치도 보호")
            expect([fake.snapshot.input, fake.snapshot.output, fake.snapshot.systemOutput] == defaultsAtAbort &&
                   fake.writes.dropFirst(writesAtAbort).allSatisfy { if case .select = $0 { return false };return true },
                   "native \(manual)/\(fault) 보상은 기본 경로를 물리·가상 장치로 임의 전환하지 않음")
            let physical = try! hal.readPhysicalProtection()
            if fault == "unreadable-device" {
                expect(physical.unconfirmedDeviceIDs.contains(80), "읽을 수 없는 실제 장치 ID는 최종 미확인으로 보존")
            }
            if fault == "setter" || fault == "streams" {
                expect(physical.coverage.contains { !$0.protected }, "setter·stream-off 미확인은 보호 성공으로 표시하지 않음")
            }
            privacy.stop()
        }
    }
}
#endif
