import Foundation
import CoreGraphics
import Darwin

private final class Event {
    var fields: [UInt32: Int64] = [41: 0, 42: 0, 45: 1]
    var location = CGPoint.zero
    func getIntegerValueField(_ field: CGEventField) -> Int64 { fields[field.rawValue] ?? 0 }
    static func tapIsEnabled(tap: Bool) -> Bool { tap }
}
private func CFMachPortIsValid(_ tap: Bool) -> Bool { tap }

@MainActor private final class Platform {
    enum State { case idle, engaging, protected, releasing, invalid(String) }
    private var state = State.protected
    private static let remoteEventTag: Int64 = 12345
    final class Label { var stringValue = "" }
    final class Panel { var ignoresMouseEvents = false; var title = ""; let level = 1001 }
    struct Curtain { let panel = Panel(); let title = Label(); let detail = Label() }
    private let curtains = [1: Curtain()]
    private var curtainMessage: (title: String, detail: String) { ("비표시 검사", reason ?? "") }
    private var currentLocalAuthenticationChallenge: () -> UUID? = { nil }
    private var changed: (() -> Void)?
    private var changingLifecycle = false
    private var localReturnDown: CGWindowID?
    private var requestLocalReturn: (() -> Void)?
    private var tap: Bool? = true
    private var usable = true
    private func environmentIsUsable() -> Bool { usable }
    private func visibleReturnButton(at point: CGPoint) -> CGWindowID? { 90 }
    __PRODUCTION__
    func run() {
        let id = UUID()
        updateCurtainText()
        Checks.check(!curtains[1]!.panel.ignoresMouseEvents, "평상시에도 커튼의 물리 클릭 차단 유지")
        let remote = Event(); remote.fields[41] = Int64(getpid()); remote.fields[42] = Self.remoteEventTag
        Checks.check(filter(.keyDown, event: remote) != nil, "challenge 없을 때 기존 원격 이벤트 통과 유지")
        currentLocalAuthenticationChallenge = { id }
        Checks.check(reason?.contains("운영체제 인증창의 연결") == true,
                     "현재 UUID만으로 OS 인증창 결박이 증명됐다고 표시하지 않음")
        updateCurtainText()
        Checks.check(!curtains[1]!.panel.ignoresMouseEvents && curtains[1]!.panel.level == 1001,
                     "인증 중 커튼 클릭 통과·레벨 하향 금지")
        for kind in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                     .rightMouseDown, .scrollWheel, .mouseMoved] {
            Checks.check(filter(kind, event: remote) == nil, "인증 중 원격 이벤트 차단 \(kind.rawValue)")
            Checks.check(filter(kind, event: Event()) == nil, "인증 중 물리 모양 이벤트도 글로벌 통과 없음 \(kind.rawValue)")
        }
        localReturnDown = 90
        _ = filter(.leftMouseUp, event: Event())
        Checks.check(localReturnDown == nil, "인증 중 이전 복귀 버튼 down 상태 제거")
        currentLocalAuthenticationChallenge = { UUID() }
        Checks.check(reason?.contains("운영체제 인증창의 연결") == true && filter(.keyDown, event: Event()) == nil,
                     "다른 현재 challenge도 인증창 연결 미확인으로 차단 유지")
        currentLocalAuthenticationChallenge = { nil }
        updateCurtainText()
        Checks.check(!curtains[1]!.panel.ignoresMouseEvents && filter(.keyDown, event: remote) != nil,
                     "취소·terminal 뒤 기존 검증 원격 경로만 복구")
        Checks.check(filter(.keyDown, event: Event()) == nil, "취소 뒤 일반 로컬 입력 차단 유지")
        remote.fields[41] = Int64(getpid()) + 1
        Checks.check(filter(.keyDown, event: remote) == nil, "원격 태그만 위조한 다른 PID 계속 거절")
        usable = false
        remote.fields[41] = Int64(getpid())
        Checks.check(filter(.keyDown, event: remote) == nil, "보안 입력 등 일반 환경 실패의 원격 거절 유지")
    }
}

@main private struct Checks {
    static var count = 0, failures = 0
    static func check(_ value: Bool, _ label: String) {
        count += 1; if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(label)")
    }
    @MainActor static func main() {
        Platform().run()
        print("NATIVE_AUTH_FAIL_CLOSED \(count - failures)/\(count)")
        exit(failures == 0 ? 0 : 1)
    }
}
