import Foundation
import Network
import StreamProtocol

@MainActor package final class HostAudioPrivacy {
    var permitted = true
    private(set) var checks = 0
    func verify() -> Bool { checks += 1; return permitted }
}

@main struct RetirementChecks {
    @MainActor static func main() async {
        let fresh = Fixture()
        expect(fresh.receiver.retirementComplete, "새 receiver는 정리 완료")
        let initiallyRetired = await fresh.receiver.waitForRetirement()
        expect(initiallyRetired, "이미 완료된 정리는 즉시 반환")

        let pending = Fixture(delayed: true)
        _ = pending.start()
        await until({ pending.continuation != nil }, "실제 준비 continuation 대기")
        expect(!pending.receiver.retirementComplete, "미완료 준비는 정리 완료 아님")
        var completed = false
        let waiting = Task { let result = await pending.receiver.waitForRetirement(); completed = true; return result }
        let cancelled = Task { await pending.receiver.waitForRetirement() }
        await settle()
        cancelled.cancel()
        let cancellation = await cancelled.value
        expect(!cancellation && !completed, "대기자 취소는 다른 대기자와 미완료 준비를 보존")
        pending.receiver.revoke(reason: "합성 연결 해제")
        await settle()
        expect(pending.receiver.phase == .retiring && !completed, "해제는 준비 완료 전 정리를 확정하지 않음")
        pending.finishPrepare()
        let retired = await waiting.value
        expect(retired && pending.receiver.retirementComplete && pending.sink.closes == 1,
               "늦은 준비 결과의 실제 close 뒤 정리 대기자를 완료")
        expect(pending.render?.isOpen == false, "늦게 도착한 준비는 PCM 입장을 열지 않음")

        let failed = Fixture()
        _ = failed.start()
        await until({ failed.receiver.phase == .active }, "활성 가짜 resource 준비")
        failed.sink.closeError = "합성 stop 실패"
        let failureWaiter = Task { await failed.receiver.waitForRetirement() }
        await settle()
        failed.receiver.revoke(reason: "합성 stop")
        let failure = await failureWaiter.value
        expect(!failure && !failed.receiver.retirementComplete && failed.receiver.phase == .cleanupFailed,
               "실패한 stop은 정리 성공으로 보고하지 않음")
        let immediateFailure = await failed.receiver.waitForRetirement()
        expect(!immediateFailure, "실패 상태의 새 대기자는 멈추지 않고 실패 반환")
        failed.receiver.retryCleanup(grantID: UUID())
        await settle()
        expect(failed.sink.closes == 1, "다른 grant의 재시도는 기존 resource를 건드리지 않음")
        failed.sink.closeError = nil
        failed.receiver.retryCleanup(grantID: failed.receiver.cleanupGrantID!)
        let retry = await failed.receiver.waitForRetirement()
        expect(retry && failed.receiver.retirementComplete && failed.sink.closes == 2,
               "동일 grant의 성공한 재시도만 정리를 완료")

        let capture = RemoteAudioCaptureLifecycle()
        expect(capture.isIdle, "새 capture lifecycle은 idle")
        var releaseStart: CheckedContinuation<Bool, Never>?
        var stopCalls = 0
        _ = capture.acquireStart { await withCheckedContinuation { releaseStart = $0 } }
        await until({ releaseStart != nil }, "실제 lifecycle의 미완료 start 대기")
        expect(!capture.isIdle, "start 슬롯은 idle 아님")
        capture.scheduleStop { stopCalls += 1 }
        await settle()
        expect(stopCalls == 0 && !capture.isIdle, "stop은 미완료 start 뒤에 실행")
        releaseStart!.resume(returning: false)
        await capture.waitUntilIdle()
        expect(capture.isIdle && stopCalls == 1, "settleStart 호출자가 없어도 stop이 start 슬롯을 정리")
        capture.scheduleStop { stopCalls += 1 }
        await capture.waitUntilIdle()
        expect(capture.isIdle && stopCalls == 2, "반복 stop은 완료 상태에 수렴")

        let ingress = MicrophoneIngress()
        let connection = NWConnection()
        let peer = ingress.authorize(connection, fingerprint: Data([1]))!
        let binding = scope(peer: peer.id)
        let request = MicrophoneControl(operation: .start, requestID: UUID(), scope: binding)
        let render = MicrophoneRenderBuffer(grant: ownerGrant(binding))
        ingress.attach(request, grantID: UUID(), render: render)
        expect(!ingress.localReturnDetached, "ingress gate가 남으면 분리 완료 아님")
        ingress.revoke()
        expect(ingress.localReturnDetached && !render.isOpen, "실제 revoke 뒤 gate와 버퍼가 분리됨")

        let privacy = HostAudioPrivacy(), hal = FakeHAL()
        hal.blackHole = true
        let owner = SillVirtualMicrophoneOwner(ops: hal.operations, privacy: privacy)
        privacy.permitted = false
        expect(owner.microphoneGrant(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), fingerprint: Data([1])) == nil,
               "Mac 보호 검증 전에는 가상 입력 grant가 없음")
        expect(hal.trace.isEmpty, "보호 실패는 HAL 조회도 하지 않음")
        privacy.permitted = true
        let grant = owner.microphoneGrant(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), fingerprint: Data([1]))!
        let virtualRender = MicrophoneRenderBuffer(grant: grant)
        let preparation = await owner.prepareMicrophone(grant: grant, render: virtualRender)
        expect(preparation.error == nil && preparation.resource != nil, "보호된 가상 장치의 주입 HAL 준비 성공")
        privacy.permitted = false
        expect(preparation.resource?.runtimeValid() == false, "보호 철회는 기존 입력 resource 유효성을 철회")
        let closed = await preparation.resource!.close()
        expect(closed == nil && !hal.running && !hal.allocated, "가상 입력은 주입 HAL의 실제 stop과 deallocate 후 종료")
        owner.restoreMicrophoneForExit()
        owner.restoreMicrophoneForExit()
        expect(privacy.permitted == false && !hal.running, "종료·반복 종료는 이전 물리 입력이나 보호 상태를 복원하지 않음")
        print("NATIVE_RETIREMENT_RESULT assertions=\(assertions)")
    }
}
