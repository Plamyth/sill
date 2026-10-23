import Foundation
import ScreenCaptureKit

private var assertions = 0
private func expect(_ value: Bool, _ label: String) {
    guard value else { fputs("FAIL \(label)\n", stderr); exit(1) }
    assertions += 1
    print("PASS \(label)")
}
private func until(_ predicate: () -> Bool) async {
    for _ in 0..<2000 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    expect(false, "가짜 캡처 경계 대기 시간 초과")
}

@main struct SystemAudioChecks {
    static func main() async throws {
        let capture = SystemAudioCapture()
        expect(capture.retirementConfirmed, "새 캡처는 정리 완료")
        try await capture.start(display: SCDisplay())
        let first = SCStream.instances.last!
        first.failuresRemaining = 1
        await capture.stop()
        expect(first.stopCalls == 2 && !capture.hasStream && capture.retirementConfirmed,
               "최초 stop 한 번 실패 뒤 동일 SCStream 재시도로 회복")
        await capture.stop()
        expect(first.stopCalls == 2 && capture.retirementConfirmed, "정리된 세대의 반복 stop은 추가 호출 없음")

        try await capture.start(display: SCDisplay())
        let permanent = SCStream.instances.last!
        permanent.failuresRemaining = 100
        await capture.stop()
        expect(permanent.stopCalls == 2 && capture.hasStream && !capture.retirementConfirmed,
               "영구 실패는 두 번에서 멈추고 동일 SCStream 참조 보존")
        let count = SCStream.instances.count
        do { try await capture.start(display: SCDisplay()); expect(false, "미정리 세대의 start 거부") } catch {}
        expect(SCStream.instances.count == count, "미정리 세대가 있으면 새 캡처를 만들지 않음")
        permanent.failuresRemaining = 0
        await capture.stop()
        expect(permanent.stopCalls == 3 && capture.retirementConfirmed,
               "후속 명시적 stop은 보존한 같은 세대를 정리")

        SCStream.delayNextStart = true
        let starting = Task { try await capture.start(display: SCDisplay()) }
        await until { SCStream.instances.count > count }
        let pending = SCStream.instances.last!
        await until { pending.startIsWaiting }
        let stopping = Task { await capture.stop() }
        try? await Task.sleep(for: .milliseconds(20))
        expect(pending.stopCalls == 0 && capture.hasStream && !capture.retirementConfirmed,
               "미완료 start가 settle되기 전에는 stop 성공으로 닫지 않음")
        pending.finishStart()
        _ = try? await starting.value
        await stopping.value
        expect(pending.prematureStops == 0 && pending.stopCalls == 1 && capture.retirementConfirmed,
               "시작 정착 후 실제 stop과 drain으로만 세대 종료")

        try await capture.start(display: SCDisplay())
        let concurrent = SCStream.instances.last!
        concurrent.delayStop = true
        let stopOne = Task { await capture.stop() }
        await until { concurrent.stopIsWaiting }
        let stopTwo = Task { await capture.stop() }
        try? await Task.sleep(for: .milliseconds(20))
        expect(concurrent.stopCalls == 1 && capture.hasStream && !capture.retirementConfirmed,
               "동일 세대의 중복 stop은 하나의 진행 작업을 공유")
        concurrent.finishStop()
        await stopOne.value
        await stopTwo.value
        expect(concurrent.stopCalls == 1 && capture.retirementConfirmed, "공유 stop의 두 대기자는 drain 후 완료")

        try await capture.start(display: SCDisplay())
        let draining = SCStream.instances.last!
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        draining.sampleQueue.async { entered.signal(); release.wait() }
        entered.wait()
        let drainStop = Task { await capture.stop() }
        await until { draining.stopCalls == 1 }
        expect(capture.hasStream && !capture.retirementConfirmed,
               "실제 stop 성공이어도 이전 sample 큐가 drain되기 전 참조 보존")
        release.signal()
        await drainStop.value
        expect(capture.retirementConfirmed, "sample 큐 barrier를 통과한 뒤 종료 확정")

        try await capture.start(display: SCDisplay())
        let newest = SCStream.instances.last!
        let callbacks = Counter()
        capture.onStopped = { _ in callbacks.increment() }
        first.sendLateError()
        concurrent.sendLateError()
        _ = await capture.subscriptionBoundary()
        expect(capture.hasStream && !capture.retirementConfirmed && callbacks.value == 0 && newest.stopCalls == 0,
               "구세대의 늦은 delegate는 새 캡처 상태와 callback을 덮지 않음")
        newest.sendLateError()
        _ = await capture.subscriptionBoundary()
        expect(capture.hasStream && !capture.retirementConfirmed && callbacks.value == 1,
               "현재 delegate 오류도 명시적 stop과 drain 전에는 참조 보존")
        await capture.stop()
        expect(capture.retirementConfirmed && newest.stopCalls == 1, "delegate 오류 뒤에도 동일 stream의 stop 가능")

        SCStream.failNextStart = true
        do { try await capture.start(display: SCDisplay()); expect(false, "시작 실패 전달") } catch {}
        let failedStart = SCStream.instances.last!
        expect(capture.hasStream && !capture.retirementConfirmed, "start 오류도 미정리 참조를 버리지 않음")
        await capture.stop()
        expect(capture.retirementConfirmed && failedStart.stopCalls == 1, "start 오류 뒤 실제 stop으로 정리")
        print("SYSTEM_AUDIO_RETIREMENT_RESULT assertions=\(assertions)")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
