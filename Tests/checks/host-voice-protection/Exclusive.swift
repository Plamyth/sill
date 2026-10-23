import AudioSilence
import CoreAudio
import Darwin
import Foundation

@MainActor
func exclusiveSilenceChecks() {
    var owner: pid_t = -1
    var running = false
    var context: OpaquePointer?
    var starts = 0, stops = 0, toggles = 0, destroys = 0
    var stopSucceeds = true
    var deviceID: UInt32 = 80
    var futureTick: UInt64?
    let proc: AudioDeviceIOProcID = SillSilenceIOProc
    let ops = HostExclusiveAudioSilence.Operations(read: {
        .init(id: deviceID, uid: "DN32-LIVE", inputChannels: 32, outputChannels: 32,
              sampleRate: 48_000, hogPID: owner, running: running)
    }, toggleHog: { toggles += 1; owner = owner == -1 ? getpid() : -1; return true }, create: {
        context = $0; return proc
    }, start: { _ in starts += 1; running = true; return true }, stop: { _ in
        stops += 1; if stopSucceeds { running = false }; return stopSucceeds
    }, destroy: { _ in destroys += 1; return true }, now: { futureTick ?? mach_continuous_time() })
    let candidate = HostExclusiveAudioSilence(ops: ops)
    expect(candidate.startCandidate() && starts == 1 && toggles == 1, "배타 무음 후보가 소유한 IOProc만 시작")
    expect(candidate.inspectCandidate() == nil, "hog PID와 start 성공만으로는 무음 증거 없음")
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: 32 * 16)
    defer { samples.deallocate() }
    samples.initialize(repeating: 0.75, count: 32 * 16)
    var input = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(mNumberChannels: 32,
        mDataByteSize: 32 * 16 * 4, mData: samples))
    let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: 32 * 16)
    defer { inputSamples.deallocate() }
    inputSamples.initialize(repeating: 0.5, count: 32 * 16)
    var output = input
    input.mBuffers.mData = UnsafeMutableRawPointer(inputSamples)
    var stamp = AudioTimeStamp()
    for _ in 0..<2 {
        let result = withUnsafePointer(to: &stamp) { time in
            withUnsafePointer(to: &input) { source in
                SillSilenceIOProc(80, time, source, time, &output, time, UnsafeMutableRawPointer(context))
            }
        }
        expect(result == noErr, "실제 C callback이 주입된 전체 32채널을 처리")
    }
    expect((0..<(32 * 16)).allSatisfy { samples[$0] == 0 }, "실제 C callback이 출력 buffer 모든 sample을 0으로 변경")
    let evidence = candidate.inspectCandidate()
    expect(evidence?.inputChannels == 32 && evidence?.outputChannels == 32 && evidence?.zeroedBytes == 2048,
           "전체 입력 폐기와 출력 무음 callback readback 확보")
    expect(evidence?.permitsRemoteAudio == false, "외부 프로세스와 믹서 실물 미검증 후보는 원격 오디오 열지 않음")
    expect(inputSamples[0] == 0.5, "입력 PCM은 저장·전달·수정 없이 폐기")
    futureTick = UInt64.max
    expect(candidate.inspectCandidate() == nil, "heartbeat 만료는 이전 무음 증거를 무효화")
    futureTick = nil
    owner = 1234
    expect(candidate.inspectCandidate() == nil && !candidate.retireAfterAuthenticatedReturn() && stops == 0,
           "장치 소유권 교체는 다른 소유자의 IO를 정지하지 않음")
    owner = getpid(); deviceID = 81
    expect(!candidate.retireAfterAuthenticatedReturn() && stops == 0, "장치 ID 재할당은 이전 IOProc 임의 조작 금지")
    deviceID = 80; stopSucceeds = false
    expect(!candidate.retireAfterAuthenticatedReturn() && destroys == 0 && toggles == 1,
           "IO 중지 실패는 callback context와 배타 권한을 유지")
    stopSucceeds = true
    expect(candidate.retireAfterAuthenticatedReturn() && destroys == 1 && owner == -1,
           "실제 stop/destroy 확인 후에만 본인이 취득한 hog 해제")
    expect(candidate.retireAfterAuthenticatedReturn() && destroys == 1, "후보 정리 재호출은 효과를 중복하지 않음")

    var staleOps = ops
    staleOps.now = { UInt64.max }
    let stale = HostExclusiveAudioSilence(ops: staleOps)
    expect(stale.startCandidate(), "callback freshness fixture 시작")
    expect(stale.inspectCandidate() == nil, "callback 없는 후보는 최신 무음 증거 아님")
    expect(stale.retireAfterAuthenticatedReturn(), "실제 장치를 건드리지 않은 freshness fixture 종료")

    running = true
    let busy = HostExclusiveAudioSilence(ops: ops)
    let priorToggles = toggles
    expect(!busy.startCandidate() && toggles == priorToggles, "사용 중인 장치는 hog 취득도 시도하지 않음")
    let count = 32
    let listBytes = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + count * MemoryLayout<AudioBuffer>.stride
    let storage = UnsafeMutableRawPointer.allocate(byteCount: listBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    let list = storage.assumingMemoryBound(to: AudioBufferList.self)
    list.pointee.mNumberBuffers = UInt32(count)
    let planar = UnsafeMutableAudioBufferListPointer(list)
    samples.update(repeating: 0.75, count: 32 * 16)
    for channel in 0..<count {
        planar[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16 * 4,
            mData: samples.advanced(by: channel * 16))
    }
    let planarContext = SillSilenceCreate(32, 32)!
    defer { SillSilenceDestroy(planarContext) }
    let planarResult = withUnsafePointer(to: &stamp) { time in
        SillSilenceIOProc(80, time, UnsafePointer(list), time, list, time, UnsafeMutableRawPointer(planarContext))
    }
    expect(planarResult == noErr && (0..<(32 * 16)).allSatisfy { samples[$0] == 0 },
           "32개의 mono buffer 전체를 실제 C callback으로 무음 처리")
    planar[31].mData = nil
    let broken = withUnsafePointer(to: &stamp) { time in
        SillSilenceIOProc(80, time, UnsafePointer(list), time, list, time, UnsafeMutableRawPointer(planarContext))
    }
    var brokenReadback = SillSilenceReadback()
    expect(broken != noErr && SillSilenceInspect(planarContext, &brokenReadback) && brokenReadback.fault,
           "32번째 buffer 접근 실패는 전체 무음 증거를 거부")

}
