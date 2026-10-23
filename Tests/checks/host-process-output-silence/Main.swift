import CoreAudio
import Foundation

@MainActor
private final class Fixture {
    typealias Candidate = HostProcessOutputSilence
    var device: Candidate.Device?
    var taps: [UInt32: Candidate.Tap] = [:]
    var creates = 0
    var destroyed: [UInt32] = []
    var failCreation = 0
    var malformed = ""
    var failedDestroy = false
    var destroyReportsFailureAfterEffect = false
    var unknownIdentity = false
    var unreadableID: UInt32?
    var replacementOwner = false
    var missingReadback = false
    var changeInventory = false

    init(transport: UInt32 = kAudioDeviceTransportTypeUSB, channels: UInt32 = 16) {
        let format = Candidate.Format(AudioStreamBasicDescription(mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0))
        device = .init(id: 80, uid: "synthetic-physical", transport: transport, outputChannels: Int(channels * 2),
            sampleRate: 48_000, streams: [
                .init(id: 90, index: 0, startingChannel: 1, virtualFormat: format, physicalFormat: format),
                .init(id: 91, index: 1, startingChannel: channels + 1, virtualFormat: format, physicalFormat: format)])
    }
    func candidate() -> Candidate {
        Candidate(uid: "synthetic-physical", ops: .init(read: { [self] in
            if changeInventory && creates > 0 { return nil }
            return device
        }, create: { [self] uid, stream, uuid in
            creates += 1
            let id = UInt32(100 + creates)
            taps[id] = .init(id: id, uuid: uuid, deviceUID: malformed == "uid" ? "virtual-remote" : uid,
                streamIndex: malformed == "stream" ? nil : stream.index,
                excludedProcesses: malformed == "exclude" ? [42] : [], isExclusive: malformed != "exclusive",
                isPrivate: malformed != "private", isMixdown: malformed == "mixdown", isMono: malformed == "mono",
                muteBehavior: malformed == "mute" ? 2 : CATapMuteBehavior.muted.rawValue,
                format: malformed == "format" ? .init(AudioStreamBasicDescription()) : stream.virtualFormat)
            return (creates == failCreation ? -1 : noErr, id)
        }, identify: { [self] id in
            if unknownIdentity || unreadableID == id { return .unreadable }
            guard let tap = taps[id] else { return .missing }
            return .tap(replacementOwner ? UUID() : tap.uuid)
        }, readTap: { [self] id in missingReadback ? nil : taps[id] }, destroy: { [self] id in
            destroyed.append(id)
            if failedDestroy { return -1 }
            taps[id] = nil
            return destroyReportsFailureAfterEffect ? -1 : noErr
        }))
    }
}

@main
private struct Checks {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }
        let good = Fixture(), candidate = good.candidate()
        expect(candidate.startCandidate() && good.creates == 2, "전체 32채널의 두 출력 스트림을 각각 취득")
        expect(!candidate.startCandidate() && good.creates == 2, "활성 후보의 재시작은 중복 tap을 만들지 않음")
        let evidence = candidate.inspectCandidate()
        expect(evidence?.taps.count == 2 && evidence?.device.outputChannels == 32, "전체 출력 inventory readback")
        expect(evidence?.permitsRemoteAudio == false && evidence?.inputProtectionAttested == false &&
            evidence?.analogMixerProtectionAttested == false && evidence?.survivesProcessDeathAttested == false,
            "출력 후보를 전체 음성·입력·믹서·프로세스 사망 보호로 승격하지 않음")
        expect(candidate.retireAfterAuthenticatedReturn() && good.destroyed == [102, 101] && !candidate.hasOwnedResources,
            "본인이 만든 tap만 역순 정리")
        expect(candidate.retireAfterAuthenticatedReturn() && good.destroyed.count == 2, "정리 재호출은 멱등")

        for transport in [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                          kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeUnknown,
                          UInt32(0x72736372), kAudioDeviceTransportTypeAirPlay] {
            let virtual = Fixture(transport: transport)
            expect(!virtual.candidate().startCandidate() && virtual.creates == 0, "가상·집계·원격 경로는 생성 전 거부")
        }
        let changedUID = Fixture()
        let original = changedUID.device!
        changedUID.device = .init(id: original.id, uid: "BlackHole", transport: original.transport,
            outputChannels: original.outputChannels, sampleRate: original.sampleRate, streams: original.streams)
        expect(!changedUID.candidate().startCandidate() && changedUID.creates == 0, "요청 UID와 실제 UID가 다르면 생성하지 않음")
        let incomplete = Fixture()
        incomplete.device = .init(id: original.id, uid: original.uid, transport: original.transport,
            outputChannels: 31, sampleRate: original.sampleRate, streams: original.streams)
        expect(!incomplete.candidate().startCandidate() && incomplete.creates == 0, "누락된 채널은 전체 출력 증거 아님")
        let duplicate = Fixture()
        duplicate.device = .init(id: original.id, uid: original.uid, transport: original.transport,
            outputChannels: original.outputChannels, sampleRate: original.sampleRate, streams: [original.streams[0], original.streams[0]])
        expect(!duplicate.candidate().startCandidate() && duplicate.creates == 0, "중복 스트림 ID는 거부")
        let invalidRate = Fixture()
        invalidRate.device = .init(id: original.id, uid: original.uid, transport: original.transport,
            outputChannels: original.outputChannels, sampleRate: .nan, streams: original.streams)
        expect(!invalidRate.candidate().startCandidate() && invalidRate.creates == 0, "유효하지 않은 형식은 생성 전 거부")

        for field in ["uid", "stream", "exclude", "exclusive", "private", "mixdown", "mono", "mute", "format"] {
            let bad = Fixture(); bad.malformed = field
            expect(!bad.candidate().startCandidate() && bad.destroyed == [101] && bad.taps.isEmpty,
                "readback 불일치인 \(field)는 본인 tap만 정리")
        }
        let partial = Fixture(); partial.failCreation = 2
        let partialCandidate = partial.candidate()
        expect(!partialCandidate.startCandidate() && partial.destroyed == [102, 101] && !partialCandidate.hasOwnedResources,
            "오류를 보고했으나 ID가 반환된 부분 생성도 소유권 확인 후 정리")
        let noReadback = Fixture(); noReadback.missingReadback = true
        expect(!noReadback.candidate().startCandidate() && noReadback.destroyed == [101],
            "형식 readback 실패에도 UUID로 소유권을 입증한 tap만 정리")
        let unreadable = Fixture(); unreadable.unknownIdentity = true
        let unreadableCandidate = unreadable.candidate()
        expect(!unreadableCandidate.startCandidate() && unreadableCandidate.hasOwnedResources && unreadable.destroyed.isEmpty,
            "생성 후 소유권 미확인은 임의 해제하지 않고 복구 상태 보존")
        unreadable.unknownIdentity = false
        expect(unreadableCandidate.retireAfterAuthenticatedReturn() && unreadable.taps.isEmpty, "소유권 확인 뒤 남은 자원 복구")
        let mixed = Fixture(); mixed.failCreation = 2; mixed.unreadableID = 102
        let mixedCandidate = mixed.candidate()
        expect(!mixedCandidate.startCandidate() && mixed.destroyed == [101] && mixed.taps[102] != nil && mixedCandidate.hasOwnedResources,
            "부분 소유권 미확인 tap은 보존하되 확인된 다른 tap은 정리")
        mixed.unreadableID = nil
        expect(mixedCandidate.retireAfterAuthenticatedReturn() && mixed.taps.isEmpty, "보류한 자원만 재확인 후 정리")
        let mutation = Fixture(); mutation.changeInventory = true
        expect(!mutation.candidate().startCandidate() && mutation.destroyed == [101], "생성 중 장치 변경은 기존 소유 tap rollback")

        let owner = Fixture(), ownerCandidate = owner.candidate()
        expect(ownerCandidate.startCandidate(), "소유권 교체 fixture")
        owner.replacementOwner = true
        expect(ownerCandidate.inspectCandidate() == nil && !ownerCandidate.retireAfterAuthenticatedReturn() && owner.destroyed.isEmpty,
            "tap ID 재할당·다른 UUID는 읽기와 정리 모두 거부")
        owner.replacementOwner = false; owner.failedDestroy = true
        expect(!ownerCandidate.retireAfterAuthenticatedReturn() && ownerCandidate.hasOwnedResources, "제거 실패는 핸들 보존")
        owner.failedDestroy = false; owner.destroyReportsFailureAfterEffect = true
        expect(ownerCandidate.retireAfterAuthenticatedReturn() && owner.taps.isEmpty, "제거 반환값보다 실제 부재 readback 확인")
        let unplug = Fixture(), unplugCandidate = unplug.candidate()
        expect(unplugCandidate.startCandidate(), "장치 제거 fixture")
        unplug.device = nil
        expect(unplugCandidate.inspectCandidate() == nil && unplugCandidate.retireAfterAuthenticatedReturn(),
            "물리 장치가 사라져도 본인 tap UUID만 정리")

        if #available(macOS 14.2, *) {
            let uuid = UUID()
            let description = HostProcessOutputSilence.Operations.description(uid: "synthetic-physical", stream: 1, uuid: uuid)
            expect(description.uuid == uuid && description.deviceUID == "synthetic-physical" && description.stream == 1,
                "실제 CATapDescription은 지정 UID와 물리 스트림 index에 결박")
            expect(description.isPrivate && description.isExclusive && description.processes.isEmpty &&
                !description.isMixdown && !description.isMono && description.muteBehavior == .muted,
                "실제 native description은 private·전체 프로세스·항상 muted이며 global mixdown을 만들지 않음")
        }
        print("PASS \(checks) 출력 tap 후보 주입 검사. 실제 HAL/tap/hog/오디오 호출 0.")
    }
}
