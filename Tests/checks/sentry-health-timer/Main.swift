import Foundation
@MainActor final class Platform {
    enum State { case protected, invalid(String) }
    var state = State.protected
    var isProtected: Bool { if case .protected = state { return true }; return false }
    var healthy = true
    var reads = 0
    var changes = 0
    var recoveries = 0
    var changed: (() -> Void)?
    var recoveryRequested: (() -> Void)?
    var recoveryTask: Task<Void, Never>?
    var localReturnDown: UInt32?
    var changingLifecycle = false
    func updateCurtainText() {}
    func verify() -> Bool {
        reads += 1
        if !healthy { invalidate("환경 확인 실패"); return false }
        return isProtected
    }
    // METHODS
    func cancelForTest() { recoveryTask?.cancel(); recoveryTask = nil }
    func makeTimer() -> Timer {
        // TIMER
        return timer
    }
}
@main struct Checks {
    @MainActor static func main() async {
        let platform = Platform()
        platform.changed = { platform.changes += 1 }
        platform.recoveryRequested = {
            precondition(!platform.changingLifecycle, "복구는 기존 상태 변경 콜백 밖에서 실행한다")
            platform.recoveries += 1
            if platform.healthy { platform.state = .protected }
        }
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<1000 { if condition() { return }; await Task.yield() }
            preconditionFailure("복구 요청 대기 초과")
        }
        let timer = platform.makeTimer()
        for _ in 0..<10 { timer.fire() }
        precondition(platform.reads == 10 && platform.changes == 0 && platform.recoveries == 0)
        platform.healthy = false
        timer.fire()
        await settle { platform.recoveries == 1 }
        precondition(platform.reads == 11 && platform.changes == 1, "verify 내부 실패 통지는 한 번만 전달한다")
        for _ in 0..<10 { timer.fire() }
        precondition(platform.reads == 11 && platform.changes == 1 && platform.recoveries == 1,
                     "알려진 실패를 주기적으로 무효화하거나 복구하지 않는다")
        platform.environmentChanged("동일한 OS 상태 변경")
        platform.environmentChanged("동일한 OS 상태 변경")
        precondition(platform.changes == 3, "같은 문구의 실제 잠금·해제 이벤트를 모두 전달한다")
        platform.healthy = true
        await settle { platform.recoveries == 2 }
        precondition(platform.isProtected, "중첩된 OS 이벤트는 최신 상태로 한 번 복구한다")
        timer.fire()
        precondition(platform.reads == 12 && platform.changes == 3 && platform.recoveries == 2)
        platform.invalidate("같은 내부 실패")
        platform.invalidate("같은 내부 실패")
        precondition(platform.changes == 4, "같은 내부 실패는 중복 통지하지 않는다")
        platform.requestRecovery()
        platform.cancelForTest()
        for _ in 0..<10 { await Task.yield() }
        precondition(platform.recoveries == 2, "해제된 세대의 대기 복구는 다시 보호를 켜지 않는다")
        timer.invalidate()
        print("PASS 8 actual Sentry timer, invalidation and OS recovery checks; no display or event tap actions")
    }
}
