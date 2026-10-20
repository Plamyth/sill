import Dispatch

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("실패: \(message)") }
}

let gain = VisionAudioGain.shared
let windowA = UUID(), windowB = UUID()
expect(gain === VisionAudioGain.shared, "모든 창이 같은 gain을 공유한다")
expect(gain.value == 1 && gain.renderGain == 1, "기본값은 기존 PCM을 보존한다")

func setGain(_ target: Double) {
    let ticket = gain.begin(owner: windowA)
    let degrees = (target - gain.value) * 180
    expect(gain.preview(ticket: ticket, degrees: degrees) == target, "검사 시작 gain을 설정한다")
    expect(gain.end(ticket: ticket, commit: true), "설정한 gain을 확정한다")
}

let first = gain.begin(owner: windowA)
expect(first.owner == windowA, "Ticket은 창 owner를 보존한다")
expect(gain.preview(ticket: first, degrees: -90) == 0.5, "반 회전은 시작값에서 0.5를 줄인다")
expect(gain.preview(ticket: first, degrees: -45) == 0.75, "미리보기는 누적값이 아닌 시작값을 사용한다")
expect(gain.value == 0.75 && gain.renderGain == 0.75, "상태와 renderer가 미리보기를 읽는다")
expect(gain.preview(ticket: first, degrees: -180) == 0, "음의 한 회전으로 0에 도달한다")
expect(gain.renderGain.bitPattern == Float(0).bitPattern, "0은 양의 정확한 Float32 무음이다")
expect(gain.preview(ticket: first, degrees: -Double.greatestFiniteMagnitude) == 0, "큰 유한 음각은 0으로 제한한다")
expect(gain.preview(ticket: first, degrees: Double.greatestFiniteMagnitude) == 1, "큰 유한 양각은 1로 제한한다")
expect(gain.preview(ticket: first, degrees: -90) == 0.5, "클램프 뒤에도 시작값을 유지한다")
for invalid in [Double.nan, Double.infinity, -Double.infinity] {
    expect(gain.preview(ticket: first, degrees: invalid) == nil, "비유한 각도를 거부한다")
    expect(gain.value == 0.5 && gain.renderGain == 0.5, "거부된 입력은 들리는 gain을 보존한다")
}
expect(gain.end(ticket: first, commit: false), "활성 Ticket 취소를 수락한다")
expect(gain.value == 1 && gain.renderGain == 1, "취소하면 시작값으로 돌아간다")
expect(gain.preview(ticket: first, degrees: -90) == nil, "종료된 Ticket 갱신을 거부한다")
expect(!gain.end(ticket: first, commit: false), "중복 취소를 거부한다")

let old = gain.begin(owner: windowA)
expect(gain.preview(ticket: old, degrees: -90) == 0.5, "첫 창의 미리보기를 적용한다")
let replacement = gain.begin(owner: windowB)
expect(replacement.id != old.id && replacement.owner == windowB, "새 창에 고유 Ticket을 발급한다")
expect(gain.value == 0.5, "새 begin은 현재 들리는 값을 유지한다")
expect(gain.preview(ticket: replacement, degrees: 45) == 0.75, "새 세대는 현재 들리는 값에서 시작한다")
expect(gain.preview(ticket: old, degrees: -180) == nil, "이전 창의 갱신을 거부한다")
expect(!gain.end(ticket: old, commit: false), "이전 창의 취소가 새 세대를 덮지 않는다")
expect(!gain.end(ticket: old, commit: true), "이전 창의 확정이 새 세대를 끝내지 않는다")
expect(gain.value == 0.75, "오래된 Ticket은 gain을 바꾸지 않는다")
expect(gain.end(ticket: replacement, commit: false), "새 창의 취소를 수락한다")
expect(gain.value == 0.5, "새 창이 시작할 때 들리던 값으로 돌아간다")
let sameOwnerOld = gain.begin(owner: windowA)
let sameOwnerNew = gain.begin(owner: windowA)
expect(sameOwnerOld.id != sameOwnerNew.id, "같은 owner의 begin에도 고유 ID를 발급한다")
expect(!gain.end(ticket: sameOwnerOld, commit: false), "같은 owner의 이전 세대도 취소할 수 없다")
expect(gain.preview(ticket: sameOwnerNew, degrees: 90) == 1, "양의 한 회전 비율을 적용한다")
expect(gain.end(ticket: sameOwnerNew, commit: true) && gain.value == 1, "확정하면 미리보기 값을 보존한다")

setGain(0)
let fromZero = gain.begin(owner: windowB)
expect(gain.preview(ticket: fromZero, degrees: 180) == 1, "0에서 양의 한 회전은 1이다")
expect(gain.preview(ticket: fromZero, degrees: 0) == 0, "0도는 시작값이다")
expect(gain.end(ticket: fromZero, commit: false) && gain.value == 0, "무음 시작값도 취소로 복원한다")

extension VisionAudioGain {
    func checkNonblockingRead() {
        control.withLock {
            expect(value == 0 && renderGain == 0, "조절 잠금이 잡혀 있어도 읽기는 대기하지 않는다")
        }
    }
}
gain.checkNonblockingRead()

let invalidRead = Atomic<Bool>(false)
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for iteration in 0..<2_000 {
        if worker.isMultiple(of: 2) {
            let ticket = gain.begin(owner: worker.isMultiple(of: 4) ? windowA : windowB)
            _ = gain.preview(ticket: ticket, degrees: Double(iteration % 721 - 360))
            _ = gain.end(ticket: ticket, commit: iteration.isMultiple(of: 2))
        } else {
            let rendered = gain.renderGain
            let value = gain.value
            if !rendered.isFinite || !(0...1).contains(rendered) || !value.isFinite || !(0...1).contains(value) {
                invalidRead.store(true, ordering: .relaxed)
            }
        }
    }
}
expect(!invalidRead.load(ordering: .relaxed), "동시 창 갱신 중 읽기는 유한한 범위를 유지한다")

struct TestAudioBuffer {
    let mData: UnsafeMutableRawPointer?
    let mDataByteSize: UInt32
}
func UnsafeMutableAudioBufferListPointer(_ list: [TestAudioBuffer]) -> [TestAudioBuffer] { list }
let noErr: Int32 = 0

final class TestRenderState {
    struct State { var playback = VisionAudioPlaybackState() }
    var value = State()
    var available = true
    func withLockIfAvailable(_ body: (inout State) -> Void) -> Bool {
        guard available else { return false }
        body(&value)
        return true
    }
}

final class TestOutput {
    var callback: ((Int, Int, UInt32, [TestAudioBuffer]) -> Int32)?
    func start(_ ticket: VisionAudioTicket, format: VisionAudioFormat, version: UInt64,
               authorization: () -> VisionAudioPlaybackAuthorization,
               render: @escaping (Int, Int, UInt32, [TestAudioBuffer]) -> Int32) throws {
        guard authorization() == .current else { throw CancellationError() }
        callback = render
    }
}

final class RendererHarness {
    static let now = 0.01
    let renderState = TestRenderState()
    let output = TestOutput()
    let ticket = VisionAudioTicket(grant: UUID(), epoch: UUID())
    let format: VisionAudioFormat
    var version: UInt64 { renderState.value.playback.version }
    init(channels: Int) { format = VisionAudioFormat(rate: 8_000, channels: channels)! }
    func fill() {
        renderState.value.playback.begin(ticket)
        let samples = (0..<(format.prefill * format.channels)).map { $0.isMultiple(of: 2) ? Float(0.8) : Float(-0.4) }
        _ = renderState.value.playback.mailbox.offer(Data([1]), ticket: ticket, now: Self.now)
        let work = renderState.value.playback.mailbox.next(now: Self.now)!
        expect(renderState.value.playback.append(samples, format: format, work: work, now: Self.now), "실제 PCM ring에 fixture를 넣는다")
        renderState.value.playback.mailbox.finish()
    }
    func install() throws {
        let renderState = renderState, output = output, ticket = ticket, format = format, version = version
        let authorization = { VisionAudioPlaybackAuthorization.current }
        __PRODUCTION_RENDER_CALLBACK__
    }
    func render(frames: Int = 4, suppliedChannels: Int? = nil, bytes: Int? = nil) -> [[Float]] {
        let pointers = (0..<(suppliedChannels ?? format.channels)).map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 99, count: frames)
            return pointer
        }
        defer { for pointer in pointers { pointer.deinitialize(count: frames); pointer.deallocate() } }
        let list = pointers.map { TestAudioBuffer(mData: UnsafeMutableRawPointer($0), mDataByteSize: UInt32(bytes ?? frames * 4)) }
        expect(output.callback!(0, 0, UInt32(frames), list) == noErr, "실제 renderer 본문이 정상 반환한다")
        return pointers.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }
}

for channels in [1, 2] {
    let renderer = RendererHarness(channels: channels)
    renderer.fill()
    try renderer.install()
    setGain(1)
    let unity = renderer.render()
    for channel in 0..<channels {
        let expected = (0..<4).map { ($0 * channels + channel).isMultiple(of: 2) ? Float(0.8) : Float(-0.4) }
        expect(unity[channel] == expected, "gain 1은 실제 mono 및 stereo sample을 보존한다")
    }
    setGain(0.5)
    expect(renderer.render() == unity.map { $0.map { $0 * 0.5 } }, "기존 callback이 새 gain으로 sample을 곱한다")
    setGain(0)
    expect(renderer.render().flatMap { $0 }.allSatisfy { $0.bitPattern == Float(0).bitPattern }, "gain 0은 모든 채널에 정확한 0을 쓴다")
    setGain(1)
    renderer.renderState.available = false
    expect(renderer.render().flatMap { $0 }.allSatisfy { $0 == 0 }, "기존 render 잠금 실패 시 무음을 보존한다")
    renderer.renderState.available = true
    _ = renderer.renderState.value.playback.revoke()
    expect(renderer.render().flatMap { $0 }.allSatisfy { $0 == 0 }, "gain 변경은 취소된 미디어 grant를 되살리지 않는다")
    renderer.fill()
    expect(renderer.render().flatMap { $0 }.allSatisfy { $0 == 0 }, "새 미디어 세대에 이전 callback은 쓸 수 없다")
    try renderer.install()
    expect(renderer.render().contains { $0.contains { $0 != 0 } }, "올바른 새 미디어 세대는 기존 renderer를 통과한다")
    expect(renderer.render(bytes: 0).flatMap { $0 }.allSatisfy { $0 == 99 }, "작은 버퍼에는 sample을 쓰지 않는다")
    if channels == 2 {
        expect(renderer.render(suppliedChannels: 1).flatMap { $0 }.allSatisfy { $0 == 0 }, "채널 부족 시 기존 무음 처리를 유지한다")
    }
}

setGain(1)
print("\(checks)개 순수 gain·PCM 연결 검사 통과. 실제 오디오·장치·HAL 실행 없음.")
