import CoreAudio
import Foundation
import StreamProtocol

private let dn32UID = "AppleUSBAudioEngine:KLARK TEKNIK:DN32-LIVE:02D37313455564310:1,2"

private func streamFormat(channels: UInt32 = 32, formatID: UInt32 = 0x6c70636d,
                          sampleRate: Double = 48_000) -> PrivacyAudioStream.Format {
    .init(sampleRate: sampleRate, formatID: formatID, flags: 12, bytesPerPacket: channels * 4,
          framesPerPacket: 1, bytesPerFrame: channels * 4, channels: channels, bitsPerChannel: 32, reserved: 0)
}

private func stream(_ id: UInt32, _ direction: PrivacyAudioScope, owner: UInt32 = 126,
                    start: UInt32 = 1, channels: UInt32 = 32, active: Bool = true,
                    writable: Bool = true, format: PrivacyAudioStream.Format? = nil,
                    physical: PrivacyAudioStream.Format? = nil) -> PrivacyAudioStream {
    .init(id: id, ownerID: owner, direction: direction, startingChannel: start,
          virtualFormat: format ?? streamFormat(channels: channels),
          physicalFormat: physical ?? streamFormat(channels: channels), active: active, activeSettable: writable)
}

@MainActor
private func streamHAL(inputActive: Bool = true, outputActive: Bool = true) -> PrivacyFakeHAL {
    let fake = PrivacyFakeHAL()
    fake.safe()
    fake.snapshot.devices.append(.init(id: 126, uid: dn32UID, transport: .other, plugin: nil,
        inputChannels: 32, outputChannels: 32, streams: [stream(127, .output, active: outputActive), stream(128, .input, active: inputActive)]))
    return fake
}

@MainActor
private final class StreamFixture {
    let fake: PrivacyFakeHAL
    let hal: CoreAudioPrivacyHAL
    let startup = NativeAudioStartup()
    var saved: LocalAudioState?
    var data: Data?
    var saving = true
    var journalReadbackHealthy = true
    var authenticated = false
    var authentications = 0
    var clears = 0
    var privacy: HostAudioPrivacy!
    private var relayRequest: LocalAudioParticipantRequest?
    private let facts = LocalAudioParticipantFacts(admissionFenced: true, startsSettled: true, mediaDetached: true,
        callbacksDrained: true, buffersEmpty: true, workersExited: true)

    init(_ supplied: PrivacyFakeHAL? = nil, legacy: LocalAudioState? = nil) {
        let fake = supplied ?? streamHAL()
        self.fake = fake
        hal = CoreAudioPrivacyHAL(ops: fake.operations)
        if let legacy {
            saved = legacy
            data = try! JSONEncoder().encode(LocalAudioJournal.Envelope(version: 2, latched: true, original: legacy))
        }
        _ = startup.construct { true }
        privacy = HostAudioPrivacy(hal: hal, latched: legacy != nil, localState: legacy, saveLocal: { [unowned self] state in
            guard saving else { return false }
            let journal = LocalAudioJournal(data: data, store: { self.data = $0 },
                load: { self.journalReadbackHealthy ? self.data : Data([0]) }, synchronize: { true })
            guard journal.write(latched: state != nil, original: state) else { return false }
            saved = journal.original
            return true
        }, clearLatch: { [unowned self] in clears += 1; return true }, authenticateLocal: { [unowned self] _ in
            authentications += 1; return authenticated
        }, nativeStartup: startup)
        privacy.revokeForLocalReturn = { true }
        privacy.inspectForLocalReturn = { [unowned self] in facts }
        privacy.authenticatedLocalReturnWillCommit = { admission in admission() }
        startup.participants.register(.relay, bootId: UUID(), control: .init(fenceAndQuiesce: { [unowned self] request in
            relayRequest = request
            return .init(request, state: .quiescent, facts: facts)
        }, inspect: { [unowned self] id in
            guard let request = relayRequest, request.operationId == id else { return nil }
            return .init(request, state: .quiescent, facts: facts)
        }))
    }
}

@MainActor
func streamSilenceChecks() async {
    let fixture = StreamFixture(streamHAL(inputActive: false))
    let original = fixture.fake.snapshot
    fixture.fake.beforeSet = {
        expect(fixture.saved?.devices.last?.streams == original.devices.last?.streams,
               "스트림 원래 active가 journal write와 readback 뒤 setter에 전달됨")
    }
    expect(fixture.privacy.armAndVerify() && fixture.privacy.verify(), "DN32 32채널 양방향 전체 stream 비활성화 보호")
    expect(fixture.fake.writes.count == 1 && fixture.fake.snapshot.devices.last?.streams?.allSatisfy({ !$0.active }) == true,
           "원래 inactive 입력은 중복 쓰지 않고 출력만 비활성화")
    expect(fixture.privacy.state.coverage?.filter { $0.uid == dn32UID }.allSatisfy {
        $0.method == "audioStreamInactive" && $0.protected && $0.channels == 32
    } == true, "stream coverage는 실제 전체 inactive readback으로 보호 표시")
    let count = fixture.fake.writes.count
    expect(fixture.privacy.reconcile() && fixture.fake.writes.count == count, "이미 inactive인 전체 stream 중복 효과 0")
    fixture.fake.beforeSet = nil
    let denied = await fixture.privacy.requestLocalReturn()
    expect(!denied && fixture.fake.writes.count == count && fixture.clears == 0,
           "인증 거부는 원 stream active 복구와 latch 해제를 실행하지 않음")
    fixture.authenticated = true
    let accepted = await fixture.privacy.requestLocalReturn()
    expect(accepted && fixture.authentications == 2 && fixture.clears == 1 &&
           fixture.saved?.matches(fixture.fake.snapshot) == true &&
           fixture.fake.snapshot.devices.last?.streams?.first(where: { $0.id == 128 })?.active == false &&
           fixture.fake.snapshot.devices.last?.streams?.first(where: { $0.id == 127 })?.active == true,
           "정상 인증·참여자 종료 후 UID와 현재 stream을 검사하여 원래 active를 각각 복구")
    fixture.privacy.stop()

    for failedRestore in 1...2 {
        let fixture = StreamFixture()
        expect(fixture.privacy.armAndVerify(), "복귀 부분 실패 fixture 보호 \(failedRestore)")
        fixture.authenticated = true
        fixture.fake.ignoreSetter = fixture.fake.writes.count + failedRestore
        let returned = await fixture.privacy.requestLocalReturn()
        expect(!returned && fixture.clears == 0 && fixture.privacy.latched && fixture.privacy.state.protected &&
               fixture.privacy.participants.isFenced && !fixture.privacy.verify() &&
               (try? fixture.fake.snapshot.plan().isEmpty) == true &&
               fixture.fake.snapshot.devices.last?.streams?.allSatisfy({ !$0.active }) == true,
               "인증 후 복구 readback 실패는 latch 해제 없이 이미 복구된 stream까지 다시 비활성화 \(failedRestore)")
        fixture.privacy.stop()
    }

    let inactive = StreamFixture(streamHAL(inputActive: false, outputActive: false))
    expect(inactive.privacy.armAndVerify() && inactive.fake.writes.isEmpty, "최초부터 모두 inactive이면 실제 주입 setter 0")
    inactive.privacy.stop()
    expect(inactive.fake.writes.isEmpty && inactive.fake.snapshot.devices.last?.streams?.allSatisfy({ !$0.active }) == true,
           "stop과 연결 정리는 stream을 복원하지 않음")

    let split = streamHAL()
    split.snapshot.devices[3].streams = [stream(127, .output, channels: 16), stream(128, .input, channels: 16),
        stream(129, .output, start: 17, channels: 16), stream(130, .input, start: 17, channels: 16)]
    let splitFixture = StreamFixture(split)
    expect(splitFixture.privacy.armAndVerify() && split.writes.count == 4 && splitFixture.privacy.verify(),
           "ASBD와 시작 채널로 파생한 여러 stream이 양방향 32채널을 빈틈 없이 차단")
    splitFixture.privacy.stop()

    for selector in [kAudioObjectPropertyClass, kAudioStreamPropertyDirection, kAudioStreamPropertyVirtualFormat] {
        let fake = streamHAL()
        var ops = fake.operations
        let originalGet = ops.read.objectGet
        ops.read.objectGet = { object, address, qualifierSize, qualifier, size, data in
            let result = originalGet(object, address, qualifierSize, qualifier, size, data)
            if object == 127 && address.pointee.mSelector == selector {
                if selector == kAudioStreamPropertyVirtualFormat { size.pointee = 4 }
                else { data.storeBytes(of: UInt32(2), as: UInt32.self) }
            }
            return result
        }
        let privacy = HostAudioPrivacy(hal: CoreAudioPrivacyHAL(ops: ops))
        expect(!privacy.armAndVerify() && fake.writes.isEmpty,
               "native stream class·direction·ASBD 바이트 크기가 미확인이면 setter 전 거부 \(selector)")
        privacy.stop()
    }

    for mutation in 0..<19 {
        let fake = streamHAL()
        let device = fake.snapshot.devices[3]
        switch mutation {
        case 0: fake.snapshot.devices[3].streams = nil
        case 1: fake.snapshot.devices[3].streams = []
        case 2: fake.snapshot.devices[3].streams = [stream(127, .output)]
        case 3: fake.snapshot.devices[3].streams = [stream(127, .output), stream(128, .input, owner: 999)]
        case 4: fake.snapshot.devices[3].streams = [stream(127, .input), stream(128, .input)]
        case 5: fake.snapshot.devices[3].streams = [stream(127, .output, start: 0), stream(128, .input)]
        case 6: fake.snapshot.devices[3].streams = [stream(127, .output, start: 2), stream(128, .input)]
        case 7: fake.snapshot.devices[3].streams = [stream(127, .output), stream(127, .input)]
        case 8: fake.snapshot.devices[3].streams = [stream(127, .output), stream(128, .input), stream(129, .output, start: 32)]
        case 9: fake.snapshot.devices[3].streams = [stream(127, .output, channels: 31), stream(128, .input)]
        case 10: fake.snapshot.devices[3].streams = [stream(127, .output, physical: streamFormat(channels: 16)), stream(128, .input)]
        case 11: fake.snapshot.devices[3].streams = [stream(127, .output, format: streamFormat(formatID: 1)), stream(128, .input)]
        case 12: fake.snapshot.devices[3].streams = [stream(127, .output, format: streamFormat(sampleRate: .nan)), stream(128, .input)]
        case 13: fake.snapshot.devices[3].streams = [stream(127, .output, writable: false), stream(128, .input)]
        case 14: fake.snapshot.devices[3].streams = [stream(127, .output, channels: 0), stream(128, .input)]
        case 15, 16, 17:
            fake.snapshot.devices[3] = .init(id: 126, uid: device.uid,
                transport: mutation == 15 ? .aggregate : mutation == 16 ? .virtual : .unknown,
                plugin: nil, inputChannels: 32, outputChannels: 32, streams: device.streams)
        default:
            fake.snapshot.devices.append(.init(id: 160, uid: "foreign", transport: .other, plugin: nil,
                inputChannels: 32, outputChannels: 0, streams: [stream(128, .input, owner: 160)]))
        }
        let privacy = StreamFixture(fake)
        expect(!privacy.privacy.armAndVerify() && !privacy.privacy.state.protected && fake.writes.isEmpty,
               "부분·미확인·외래·겹침·누락·format·setter·aggregate 거부 \(mutation)")
        privacy.privacy.stop()
    }

    for index in 1...2 {
        for failure in [true, false] {
            let fake = streamHAL()
            if failure { fake.failSetter = index } else { fake.ignoreSetter = index }
            let fixture = StreamFixture(fake)
            expect(!fixture.privacy.armAndVerify() && !fixture.privacy.state.protected && fake.writes.count == index,
                   "stream setter 실패 또는 성공 보고 뒤 불일치 readback 거부 \(index) \(failure)")
            fake.failSetter = nil; fake.ignoreSetter = nil
            expect(fixture.privacy.reconcile() && fixture.privacy.verify(), "같은 journal과 stream 정체성으로 실패 후 재보호")
            fixture.privacy.stop()
        }
    }

    for mutation in 0..<3 {
        let fake = streamHAL(), fixture = StreamFixture(fake)
        fake.afterSet = {
            fake.afterSet = nil
            if mutation == 0 { fake.missingSelector = kAudioStreamPropertyIsActive }
            else if mutation == 1 {
                let d = fake.snapshot.devices[3]
                fake.snapshot.devices[3] = .init(id: 126, uid: "replacement", transport: .other, plugin: nil,
                    inputChannels: 32, outputChannels: 32, streams: d.streams)
            } else { fake.snapshot.devices[3].streams = [stream(137, .output), stream(128, .input, active: false)] }
        }
        expect(!fixture.privacy.armAndVerify() && !fixture.privacy.state.protected && fake.writes.count == 1,
               "setter 직후 readback 소실·UID 교체·stream ID 변경을 다음 쓰기 전에 거부 \(mutation)")
        fixture.privacy.stop()
    }

    for selector in [kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
                     kAudioStreamPropertyStartingChannel, kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
        let fake = streamHAL(); fake.rejectedStreamListener = selector
        let fixture = StreamFixture(fake)
        expect(!fixture.privacy.armAndVerify() && fake.writes.isEmpty, "stream 속성 listener 실패는 보호를 열지 않음 \(selector)")
        fixture.privacy.stop()
    }

    let stale = streamHAL()
    let staleWrite = try! stale.snapshot.plan().first!
    let staleOpsHAL = CoreAudioPrivacyHAL(ops: stale.operations)
    stale.snapshot.devices[3].streams = [stream(137, .output), stream(128, .input)]
    expect(!staleOpsHAL.write(staleWrite) && stale.writes.isEmpty, "다른 stream ID로 바뀐 topology의 지연 명령 거부")
    let changing = streamHAL()
    changing.beforeGet = { object, selector in
        if object == 128 && selector == kAudioStreamPropertyIsActive {
            changing.beforeGet = nil
            let d = changing.snapshot.devices[3]
            changing.snapshot.devices[3] = .init(id: 126, uid: "replaced-before-write", transport: .other,
                plugin: nil, inputChannels: 32, outputChannels: 32, streams: d.streams)
        }
    }
    let changingHAL = CoreAudioPrivacyHAL(ops: changing.operations)
    expect(!changingHAL.write(try! changing.snapshot.plan().first!) && changing.writes.isEmpty,
           "stream 관측 중 UID 변경은 property write 전에 거부")

    let events = StreamFixture()
    expect(events.privacy.armAndVerify(), "stream 변경 이벤트 fixture 보호")
    var states: [Bool] = []
    events.privacy.changed = { states.append($0.protected) }
    events.fake.snapshot.devices[3].streams?[1].active = true
    events.fake.fire(kAudioStreamPropertyIsActive, object: 128)
    try? await Task.sleep(for: .milliseconds(220))
    expect(states.contains(false) && events.privacy.verify(), "stream 재활성화 이벤트가 보호를 취소하고 readback 뒤 재보호")
    for selector in [kAudioObjectPropertyClass, kAudioObjectPropertyOwner, kAudioStreamPropertyDirection, kAudioStreamPropertyStartingChannel,
                     kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
        expect(events.fake.isListening(128, selector, kAudioObjectPropertyScopeGlobal), "현재 stream 정체성·format 감시 \(selector)")
    }
    let beforeAddition = events.fake.writes.count
    let d = events.fake.snapshot.devices[3]
    events.fake.snapshot.devices[3] = .init(id: d.id, uid: d.uid, transport: d.transport, plugin: nil,
        inputChannels: 32, outputChannels: 64,
        streams: d.streams! + [stream(129, .output, start: 33)])
    events.saving = false
    events.fake.fire(kAudioDevicePropertyStreams, object: 126)
    try? await Task.sleep(for: .milliseconds(220))
    expect(!events.privacy.state.protected && events.fake.writes.count == beforeAddition,
           "추가 stream 원래 active의 durable 저장 실패는 setter를 막음")
    events.saving = true
    expect(events.privacy.reconcile() && events.fake.writes.count == beforeAddition + 1 &&
           events.saved?.devices.last?.streams?.first(where: { $0.id == 129 })?.active == true &&
           events.saved?.devices.last?.streams?.first(where: { $0.id == 127 })?.active == true,
           "추가 전체 stream은 원래 active를 먼저 저장하고 기존 원본을 보존하며 재보호")
    events.fake.snapshot.devices[3].streams = [stream(137, .output, active: false), stream(128, .input, active: false), stream(129, .output, start: 33, active: false)]
    let beforeStaleRestore = events.fake.writes.count
    expect(!events.hal.restoreLocal(events.saved!) && events.fake.writes.count == beforeStaleRestore,
           "정상 UID라도 stale stream ID가 섞인 복구는 실제 setter 전에 거부")
    expect(!events.privacy.reconcile(), "재접속의 다른 stream ID를 이전 journal 정체성으로 승격하지 않음")
    events.privacy.stop()

    let journalFixture = StreamFixture()
    expect(journalFixture.privacy.armAndVerify(), "영속 stream snapshot fixture 보호")
    let journal = LocalAudioJournal(data: journalFixture.data, store: { _ in }, load: { journalFixture.data }, synchronize: { true })
    expect(journal.original == journalFixture.saved && journal.latched, "stream 원본 journal 재실행 decode가 정확함")
    let relaunched = HostAudioPrivacy(hal: journalFixture.hal, latched: true, localState: journal.original)
    let existingWrites = journalFixture.fake.writes.count
    expect(relaunched.reconcile() && journalFixture.fake.writes.count == existingWrites, "재실행은 저장된 active 원본을 바꾸거나 중복 비활성화하지 않음")
    relaunched.stop(); journalFixture.privacy.stop()

    var legacyJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(journalFixture.saved!)) as! [String: Any]
    legacyJSON["devices"] = (legacyJSON["devices"] as! [[String: Any]]).map { device in
        var device = device; device.removeValue(forKey: "streams"); return device
    }
    let legacy = try! JSONDecoder().decode(LocalAudioState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
    expect(legacy.isValid && legacy.devices.allSatisfy { $0.streams == nil }, "기존 version 2 journal의 선택 stream 필드 부재는 decode 유지")
    await legacyLatchedStreamChecks()

    for mutation in 0..<5 {
        let fake = streamHAL(), fixture = StreamFixture(fake)
        expect(fixture.privacy.armAndVerify(), "복구 정체성 실패 fixture 보호 \(mutation)")
        let original = fixture.saved!
        switch mutation {
        case 0: fake.snapshot.devices.removeLast()
        case 1:
            let d = fake.snapshot.devices[3]
            fake.snapshot.devices[3] = .init(id: 126, uid: "impostor", transport: .other, plugin: nil,
                inputChannels: 32, outputChannels: 32, streams: d.streams)
        case 2: fake.snapshot.devices[3].streams = [stream(127, .output, active: false, physical: streamFormat(sampleRate: 44_100)), stream(128, .input, active: false)]
        case 3: fake.snapshot.devices[3].streams = [stream(127, .output, active: false, writable: false), stream(128, .input, active: false)]
        default: fake.snapshot.devices[3].streams = [stream(127, .output, start: 2, active: false), stream(128, .input, active: false)]
        }
        let writes = fake.writes.count
        expect(!fixture.hal.restoreLocal(original) && fake.writes.count == writes,
               "복구 중 누락·UID·format·setter·시작 채널 불일치 거부 \(mutation)")
        fixture.privacy.stop()
    }
    print("Stream silence: injected production boundary checks passed; actual HAL writes 0; audio streams started 0")
}

@MainActor
private func legacyLatchedStreamChecks() async {
    let fake = streamHAL(inputActive: false, outputActive: true)
    let currentStreams = fake.snapshot.devices[3].streams!
    var oldSnapshot = fake.snapshot
    oldSnapshot.input = 10; oldSnapshot.output = 10; oldSnapshot.systemOutput = 10
    oldSnapshot.devices[0].inputMuted = false; oldSnapshot.devices[0].outputMuted = false
    oldSnapshot.devices[3].streams = nil
    let oldOriginal = try! LocalAudioState(oldSnapshot)
    let fixture = StreamFixture(fake, legacy: oldOriginal)
    fixture.saving = false
    expect(!fixture.privacy.reconcile() && fake.writes.isEmpty && fixture.saved == oldOriginal && fixture.privacy.latched,
           "구 v2 latched 최초 stream 원본 저장 실패는 setter 0과 기존 원상태 보존")
    fixture.saving = true; fixture.journalReadbackHealthy = false
    expect(!fixture.privacy.reconcile() && fake.writes.isEmpty && fixture.saved == oldOriginal,
           "구 v2 최초 stream merge의 journal readback 실패는 setter 0")
    fixture.journalReadbackHealthy = true
    fake.beforeSet = {
        let merged = fixture.saved!
        let readback = try! JSONDecoder().decode(LocalAudioJournal.Envelope.self, from: fixture.data!)
        expect(merged.inputUID == oldOriginal.inputUID && merged.outputUID == oldOriginal.outputUID &&
               merged.systemOutputUID == oldOriginal.systemOutputUID && merged.devices[0] == oldOriginal.devices[0] &&
               merged.devices[3].streams == currentStreams && readback.original == merged,
               "구 v2의 알려진 mute·기본 UID 원상을 보존하고 정확 active를 journal readback한 뒤에만 비활성화")
    }
    expect(fixture.privacy.reconcile() && fixture.privacy.verify() && fake.writes.count == 1,
           "구 v2 latched가 최초 stream 원본 merge 뒤 전체 보호로 전환")
    fake.beforeSet = nil
    let journal = LocalAudioJournal(data: fixture.data, store: { _ in }, load: { fixture.data }, synchronize: { true })
    expect(journal.original == fixture.saved && journal.original?.devices[3].streams == currentStreams,
           "구 v2 merge는 inactive 입력을 true로 추정하지 않고 현재 관측 그대로 영속 보존")
    fixture.privacy.stop()
    let relaunched = HostAudioPrivacy(hal: fixture.hal, latched: true, localState: journal.original)
    expect(relaunched.reconcile() && fake.writes.count == 1, "구 v2 merge 후 재실행은 stream 원본 재기록과 중복 효과 0")
    relaunched.stop()
    expect(fixture.privacy.reconcile(), "구 v2 merge 이후 정상 인증 복귀를 위한 감시 재개")
    fixture.authenticated = true
    let returned = await fixture.privacy.requestLocalReturn()
    expect(returned && fixture.clears == 1 && fixture.saved?.matches(fake.snapshot) == true &&
           fake.snapshot.input == 10 && fake.snapshot.output == 10 && fake.snapshot.systemOutput == 10 &&
           fake.snapshot.devices[0].inputMuted == false && fake.snapshot.devices[0].outputMuted == false &&
           fake.snapshot.devices[3].streams == currentStreams,
           "구 v2 업그레이드 후 인증 복귀는 옛 mute·기본 장치와 최초 관측 stream active를 모두 복원")
    fixture.privacy.stop()
}
