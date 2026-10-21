@MainActor enum Results {
    static var assertions = 0
    static var failures = 0
}
@MainActor func check(_ value: @autoclosure () -> Bool, _ label: String) {
    Results.assertions += 1
    if !value() { Results.failures += 1; print("FAIL \(label)") }
}
@MainActor func fresh() -> (Harness, NWConnection) {
    Clock.now = 10000
    Clock.sleeping = nil
    let host = Harness(), peer = NWConnection()
    host.join(peer)
    return (host, peer)
}
@MainActor func pristine(_ host: Harness, _ label: String) {
    check(host.injector.targets.isEmpty, label + " 주입 없음")
    check(host.gestureChords.open == nil && !host.gestureChords.repeated, label + " 상태 오염 없음")
}
@MainActor func checks() async {
    let decoded = Wire.decode(TrackpadGesture.self, from: Data(#"{"gesture":"swipeUp"}"#.utf8))
    check(decoded?.fingers == nil && decoded?.gesture == "swipeUp" && TrackpadGesture.generation == 1, "세대 1 optional nil wire 호환")
    for fingers: Int? in [nil, 3, 4] {
        let (h, p) = fresh()
        await h.send(fingers: fingers, from: p)
        await InertTask.drain()
        check(h.injector.targets == [.desktop] && h.gestureChords.open == .missionControl, "유효한 손가락 \(String(describing: fingers))")
    }
    for (name, fingers) in [("bad", 3), ("swipeUp", 0), ("swipeUp", 2), ("swipeUp", 5), ("swipeUp", -1)] {
        let (h, p) = fresh()
        await h.send(name, fingers: fingers, from: p)
        await InertTask.drain()
        pristine(h, "잘못된 이름·손가락 \(name) \(fingers)")
    }
    let mutations: [(String, (Harness, NWConnection) -> Void)] = [
        ("연결 종료", { h, p in h.leave(p) }),
        ("같은 객체 재가입", { h, p in h.leave(p); h.join(p) }),
        ("연결 취소", { _, p in p.state = .cancelled }),
        ("연결 대기", { _, p in p.state = .waiting }),
        ("다른 연결로 교체", { h, p in h.connections[ObjectIdentifier(p)] = NWConnection() }),
        ("입력 참여 해제", { h, p in h.inputFence.leave(ObjectIdentifier(p)) }),
        ("입력 세대 변경", { h, _ in h.inputGeneration = UUID().uuidString }),
        ("영상 변경", { h, _ in h.readyEpoch() }),
        ("영상 제거", { h, _ in h.videoEpoch = nil }),
        ("선택 변경", { h, _ in h.changeSelection() }),
        ("전환 중", { h, _ in h.switching = true }),
        ("window 도달 금지", { h, _ in h.active = .window(7) }),
        ("소스 없음", { h, _ in h.active = .none }),
        ("shutdown", { h, _ in h.shuttingDown = true }),
        ("큐 만료", { _, _ in Clock.now += 2.01 }),
        ("세대 ABA", { h, _ in let old = h.inputGeneration; h.inputGeneration = UUID().uuidString; h.inputGeneration = old }),
        ("영상 ABA", { h, _ in let old = h.videoEpoch; h.readyEpoch(); h.videoEpoch = old }),
        ("전환 ABA", { h, _ in h.switching = true; h.switching = false }),
        ("소스 ABA", { h, _ in let gen = h.inputGeneration; let epoch = h.videoEpoch; h.active = .window(7); h.active = .desktop; h.inputGeneration = gen; h.videoEpoch = epoch })
    ]
    for (label, mutate) in mutations {
        let (h, p) = fresh()
        await h.send(from: p)
        mutate(h, p)
        await InertTask.drain()
        h.switching = false
        pristine(h, "drain " + label)
        check(h.gestureDrain == nil, "drain 종료 " + label)
    }
    for (label, mutate) in mutations {
        let (h, p) = fresh()
        h.holdUntil = Clock.now + 1
        await h.send(from: p)
        await InertTask.drain()
        check(h.heldInput.count == 1, "held 대기 " + label)
        check(h.gestureChords.open == nil && !h.gestureChords.repeated, "held 이전 상태 보존 " + label)
        mutate(h, p)
        h.switching = false
        h.releaseHeldInput()
        pristine(h, "마지막 held 지연 " + label)
    }
    for label in ["switching", "window", "none", "generation", "missing-epoch", "incomplete-epoch", "epoch-generation", "epoch-source", "scope", "unjoined", "cancelled"] {
        let (h, p) = fresh()
        switch label {
        case "switching": h.switching = true
        case "window": h.active = .window(7); h.readyEpoch()
        case "none": h.active = .none; h.readyEpoch()
        case "generation": h.inputGeneration = ""
        case "missing-epoch": h.videoEpoch = nil
        case "incomplete-epoch": h.videoEpoch = VideoEpoch(generation: h.inputGeneration, source: .desktop, geometry: .init(x: 0, y: 0, width: 0, height: 0), width: 0, height: 0)
        case "epoch-generation": h.inputGeneration = UUID().uuidString
        case "epoch-source": h.videoEpoch = VideoEpoch(generation: h.inputGeneration, source: .window(7), geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
        case "scope": h.catalog.displayInventory.invalidate()
        case "unjoined": h.leave(p)
        case "cancelled": p.state = .cancelled
        default: break
        }
        await h.send(from: p)
        check(h.pendingGestures.isEmpty && h.gestureDrain == nil, "수신 거부 " + label)
        h.switching = false
        await InertTask.drain()
        pristine(h, "수신 " + label)
    }
    do {
        let (h, p) = fresh()
        await h.send(from: p)
        h.gestureDrain?.cancel()
        await InertTask.drain()
        pristine(h, "drain 취소")
        check(h.pendingGestures.isEmpty && h.gestureDrain == nil, "취소 큐 비움")
        await h.send("swipeDown", from: p)
        await InertTask.drain()
        check(h.injector.targets == [.desktop] && h.gestureChords.open == .appExpose, "취소 후 새 큐")
    }
    do {
        let (h, a) = fresh()
        let b = NWConnection(); h.join(b)
        await h.send(from: a)
        await h.send("swipeDown", from: b)
        h.leave(a)
        await InertTask.drain()
        check(h.injector.targets == [.desktop] && h.gestureChords.open == .appExpose, "끊긴 연결만 폐기하고 다른 연결 유지")
    }
    do {
        let (h, a) = fresh()
        let b = NWConnection(); h.join(b)
        h.holdUntil = Clock.now + 1
        await h.send(from: a)
        await InertTask.drain()
        await h.send("swipeDown", from: b)
        await InertTask.drain()
        h.leave(a)
        h.releaseHeldInput()
        check(h.injector.targets == [.desktop] && h.gestureChords.open == .appExpose, "held 연결별 유효성 및 상태 격리")
    }
    do {
        let (h, p) = fresh()
        let id = ObjectIdentifier(p)
        h.holdUntil = Clock.now + 1
        h.injector.owed.insert(id)
        h.deliver(.key(hidUsage: 42, down: false, modifiers: 0), in: .zero, from: id)
        await h.send(from: p)
        await h.send("swipeDown", from: p)
        await InertTask.drain()
        h.releaseInput(of: id)
        h.releaseHeldInput()
        let key = GestureChords.chord(for: .missionControl, table: GestureChords.defaults)
        if case .chord(_, _, let code, _) = key {
            check(h.injector.trace == ["up:null", "chord:\(code)", "chord:\(code)", "disconnect"], "기존 키 해제·제스처·disconnect 순서")
        } else { check(false, "기본 단축키 존재") }
        check(h.gestureChords.open == nil && h.injector.owed.isEmpty, "정상 반대 제스처 및 키 해제")
    }
    do {
        let (h, p) = fresh()
        h.holdUntil = Clock.now + 1
        h.deliver(.text("fixture"), in: .zero, from: ObjectIdentifier(p))
        await h.send(from: p)
        await InertTask.drain()
        h.injector.afterApply = { h.active = .window(7) }
        h.releaseHeldInput()
        check(h.injector.trace == ["input"], "같은 held 재생 도중 전환 뒤 window 주입 금지")
        check(h.gestureChords.open == nil, "앞선 held 입력 이후 상태 재검증")
    }
    do {
        let (h, p) = fresh()
        await h.send(from: p)
        h.onHotKeys = { h.active = .window(7) }
        await InertTask.drain()
        pristine(h, "최종 단축키 조회 후 컨텍스트 취소")
    }
    check(InertTask.pending.isEmpty, "소유한 inert 작업 종료")
    print("\(Results.failures == 0 ? "PASS" : "FAIL") \(Results.assertions) assertions, \(Results.failures) failures; inert dependencies only")
}
@main struct GestureDrainChecks {
    @MainActor static func main() async {
        await checks()
        if Results.failures != 0 { exit(1) }
    }
}
