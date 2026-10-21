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
@MainActor func settle(_ host: Harness, _ gate: SelectionGate, _ selection: Task<Void, Never>, success: Bool = true) async {
    gate.release(success)
    await selection.value
    host.catalog.refresh = nil
}
@MainActor func selectionChecks() async {
    for fingers: Int? in [nil, 3, 4] {
        for held in [false, true] {
            let (h, p) = fresh()
            let (gate, selection) = await h.beginWindowSelection(from: p)
            await h.send(fingers: fingers, from: p)
            pristine(h, "Desktop 완료 전 \(String(describing: fingers))")
            Clock.sleeping = {
                Clock.sleeping = nil
                await settle(h, gate, selection)
                if held { h.holdUntil = Clock.now + 1 }
            }
            await InertTask.drain()
            await settle(h, gate, selection)
            if held {
                pristine(h, "선택 완료 후 held 대기")
                check(h.heldInput.count == 1, "정상 순정 창→Desktop held 보존")
                h.releaseHeldInput()
            }
            check(h.injector.targets == [.desktop] && h.gestureChords.open == .missionControl,
                  "정상 순정 창→Desktop \(String(describing: fingers)) held=\(held)")
        }
    }
    do {
        let (h, p) = fresh()
        let (gate, selection) = await h.beginWindowSelection(from: p)
        Clock.now += 1.9
        await h.send(from: p)
        Clock.sleeping = { Clock.sleeping = nil; await settle(h, gate, selection) }
        await InertTask.drain()
        await settle(h, gate, selection)
        check(h.injector.targets == [.desktop], "선택 요청 TTL 안의 늦은 제스처")
    }
    for boundary in [false, true] {
        let (h, p) = fresh()
        let (gate, selection) = await h.beginWindowSelection(from: p)
        if boundary { Clock.now += 2 }
        await h.send(from: p)
        if !boundary { Clock.now += 2 }
        await settle(h, gate, selection)
        await InertTask.drain()
        pristine(h, boundary ? "수신 전 선택 TTL 만료" : "대기 중 선택 TTL 만료")
    }
    for success in [false, true] {
        let (h, p) = fresh()
        h.failPipeline = success
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: p)
        await settle(h, gate, selection, success: success)
        await InertTask.drain()
        pristine(h, success ? "pipeline 실패" : "catalog 선택 실패")
    }
    do {
        let (h, p) = fresh()
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: p)
        selection.cancel()
        await settle(h, gate, selection)
        await InertTask.drain()
        pristine(h, "선택 작업 취소")
    }
    for stage in ["before", "after", "held"] {
        let invalidations: [(String, (Harness, NWConnection) -> Void)] = [
            ("연결 종료", { h, p in h.leave(p) }),
            ("재가입", { h, p in
                let switching = h.switching
                h.leave(p); h.switching = false; h.join(p); h.switching = switching
            }),
            ("연결 교체", { h, p in h.connections[ObjectIdentifier(p)] = NWConnection() }),
            ("연결 상태", { _, p in p.state = .cancelled }),
            ("세대 ABA", { h, _ in let old = h.inputGeneration; h.inputGeneration = UUID().uuidString; h.inputGeneration = old }),
            ("epoch ABA", { h, _ in let old = h.videoEpoch; h.readyEpoch(); h.videoEpoch = old }),
            ("source ABA", { h, _ in let old = h.active; h.active = .none; h.active = old }),
            ("switch ABA", { h, _ in h.switching = false; h.switching = true; h.switching = false }),
            ("다른 디스플레이", { h, _ in
                let old = h.catalog.displayInventory.current!
                h.catalog.displayInventory.select(.init(displayID: 2, inventoryID: old.inventoryID))
            }),
            ("디스플레이 ABA 알림", { h, _ in
                let old = h.catalog.displayInventory.current!
                h.catalog.displayInventory.select(.init(displayID: 2, inventoryID: old.inventoryID))
                h.displaysChanged()
                h.catalog.displayInventory.select(old)
            }),
            ("shutdown", { h, _ in h.shuttingDown = true }),
            ("만료", { _, _ in Clock.now += 2 })
        ]
        for (label, invalidate) in invalidations {
            let (h, p) = fresh()
            let (gate, selection) = await h.beginWindowSelection(from: p)
            await h.send(from: p)
            if stage == "before" { h.beforePipelineCommit = { invalidate(h, p) } }
            if stage == "after" { h.afterPipelineCommit = { invalidate(h, p) } }
            await settle(h, gate, selection)
            if stage == "held" { h.holdUntil = Clock.now + 1 }
            await InertTask.drain()
            if stage == "held" {
                check(h.heldInput.count == 1, "선택에서 유래한 held " + label)
                invalidate(h, p)
                h.switching = false
                h.releaseHeldInput()
            }
            pristine(h, "선택 \(stage) " + label)
        }
    }
    for request in ["same", "other-peer", "window", "same-display", "other-display", "restart"] {
        let (h, p) = fresh()
        let q = NWConnection(); h.join(q)
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: p)
        switch request {
        case "same": await h.pick(.desktop, from: p)
        case "other-peer": await h.pick(.desktop, from: q)
        case "window": await h.pick(.window(8), from: p)
        case "same-display": await h.pickDisplay(1, from: p)
        case "other-display": await h.pickDisplay(2, from: p)
        default: await h.select(.window(7))
        }
        await settle(h, gate, selection)
        await InertTask.drain()
        pristine(h, "중첩 요청 " + request)
    }
    do {
        let (h, p) = fresh()
        let q = NWConnection(); h.join(q)
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: q)
        await settle(h, gate, selection)
        await InertTask.drain()
        pristine(h, "다른 참여자의 선택을 빌리지 않음")
    }
    do {
        let (h, p) = fresh()
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: p)
        await settle(h, gate, selection)
        h.holdUntil = Clock.now + 1
        await InertTask.drain()
        await h.pick(.desktop, from: p)
        h.releaseHeldInput()
        pristine(h, "완료 후 새 선택의 결과로 held 승격 금지")
    }
    for restarting in [false, true] {
        let (h, p) = fresh()
        h.active = .window(7); h.readyEpoch()
        let gate = SelectionGate()
        h.beforePipelineCommit = { _ = await gate.wait() }
        let task = Task { await h.select(restarting ? .window(7) : .window(8)) }
        while !gate.entered { await Task.yield() }
        await h.pick(.desktop, from: p)
        await h.send(from: p)
        gate.release()
        await task.value
        h.beforePipelineCommit = nil
        await InertTask.drain()
        pristine(h, restarting ? "이미 restart 중인 요청" : "이미 다른 소스 전환 중인 요청")
        check(h.active == (restarting ? .desktop : .window(8)), "기존 restart 뒤 선택 처리 보존")
    }
    do {
        let (h, p) = fresh()
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(from: p)
        h.gestureDrain?.cancel()
        await settle(h, gate, selection)
        await InertTask.drain()
        pristine(h, "선택 대기 drain 취소")
    }
    do {
        let h = Harness(), p = NWConnection()
        let id = ObjectIdentifier(p)
        check(h.inputFence.join(id, source: h.active, switching: false, desktopScope: h.desktopScope),
              "이미 Desktop인 세대 1 클라이언트 가입")
        h.connections[id] = p
        await h.send(fingers: nil, from: p)
        await InertTask.drain()
        check(h.injector.targets == [.desktop] && h.gestureChords.open == .missionControl,
              "Android 이미 Desktop 세대 1 무필드 제스처 보존")
    }
    for name in ["swipeUp", "swipeDown"] {
        let (h, p) = fresh()
        await h.send(from: p)
        await InertTask.drain()
        await h.send(from: p)
        await InertTask.drain()
        let targets = h.injector.targets
        let (gate, selection) = await h.beginWindowSelection(from: p)
        await h.send(name, from: p)
        h.afterPipelineCommit = { h.readyEpoch() }
        await settle(h, gate, selection)
        await InertTask.drain()
        check(h.injector.targets == targets && h.gestureChords.open == .missionControl && h.gestureChords.repeated,
              "선택 거부 뒤 기존 open/repeated 보존 " + name)
    }
    Clock.sleeping = nil
}
@MainActor func checks() async {
    var legacy = SourceInputFence<String>()
    check(!legacy.contains("old"), "가입 전 입력 참여 없음")
    check(legacy.join("old", source: .desktop, switching: false, desktopScope: "A"), "기존 클라이언트 가입")
    check(!legacy.join("old", source: .desktop, switching: false, desktopScope: "A"), "중복 가입 거부")
    check(!legacy.join("busy", source: .desktop, switching: true, desktopScope: "A"), "전환 중 가입 거부")
    check(legacy.allowsSelection(.none), "기존 클라이언트 연결 중 정지 허용")
    check(legacy.allowsSelection(.desktop, desktopScope: "A"), "기존 화면 선택 유지")
    check(!legacy.allowsSelection(.desktop, desktopScope: "B"), "기존 클라이언트의 다른 모니터 선택 차단")
    check(!legacy.allowsSelection(.window(7)), "기존 클라이언트의 다른 소스 선택 차단")
    check(legacy.accepts("old", generation: nil, current: "G", source: .desktop, desktopScope: "A"), "기존 무세대 입력 허용")
    check(!legacy.accepts("old", generation: nil, current: "G", source: .desktop, desktopScope: "B"), "기존 무세대 입력의 잘못된 화면 거부")
    check(!legacy.accepts("old", generation: "bad", current: "G", source: .desktop, desktopScope: "A"), "잘못된 세대 거부")
    check(legacy.accepts("old", generation: nil, current: "G", source: .desktop, desktopScope: "A"), "잘못된 세대가 기존 참여를 승격하지 않음")
    check(legacy.join("modern", source: .desktop, switching: false, desktopScope: "A"), "다른 클라이언트 동시 가입")
    legacy.negotiate("modern", supportsScoped: true)
    check(!legacy.allowsSelection(.window(7)), "기존 클라이언트가 남으면 소스 고정 유지")
    check(!legacy.accepts("modern", generation: nil, current: "G", source: .desktop, desktopScope: "A"), "새 클라이언트 무세대 입력 거부")
    check(legacy.accepts("modern", generation: "G", current: "G", source: .desktop, desktopScope: "A"), "새 클라이언트의 정확한 세대 입력 허용")
    legacy.leave("old")
    check(!legacy.contains("old") && legacy.contains("modern"), "연결별 참여 해제")
    check(legacy.allowsSelection(.window(7)), "기존 클라이언트 종료 후 소스 고정 해제")
    check(!legacy.accepts("old", generation: "G", current: "G", source: .desktop, desktopScope: "A"), "종료된 연결 입력 거부")
    check(legacy.join("old", source: .window(7), switching: false), "기존 클라이언트 재가입")
    legacy.negotiate("old", supportsScoped: false)
    check(!legacy.allowsSelection(.window(8)), "미지원 협상은 소스 고정 유지")
    check(legacy.accepts("old", generation: "G", current: "G", source: .window(7)), "정확한 세대 입력으로 참여 승격")
    check(legacy.allowsSelection(.window(8)), "모든 참여 승격 후 소스 고정 해제")
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
        ("scope만 변경", { h, _ in let selection = h.catalog.displayInventory.current!; h.catalog.displayInventory.select(.init(displayID: 2, inventoryID: selection.inventoryID)) }),
        ("전환 중", { h, _ in h.switching = true }),
        ("window 도달 금지", { h, _ in h.active = .window(7) }),
        ("소스 없음", { h, _ in h.active = .none }),
        ("shutdown", { h, _ in h.shuttingDown = true }),
        ("큐 만료", { _, _ in Clock.now += 2.01 }),
        ("만료 경계", { _, _ in Clock.now += 2 }),
        ("세대 ABA", { h, _ in let old = h.inputGeneration; h.inputGeneration = UUID().uuidString; h.inputGeneration = old }),
        ("영상 ABA", { h, _ in let old = h.videoEpoch; h.readyEpoch(); h.videoEpoch = old }),
        ("전환 ABA", { h, _ in h.switching = true; h.switching = false }),
        ("선택 ABA", { h, _ in
            let gen = h.inputGeneration, epoch = h.videoEpoch, selection = h.catalog.displayInventory.current!
            h.changeSelection()
            h.catalog.displayInventory.select(selection)
            h.inputGeneration = gen; h.videoEpoch = epoch
        }),
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
        for name in ["swipeUp", "swipeDown"] {
            let (h, p) = fresh()
            await h.send(from: p)
            await InertTask.drain()
            let trace = h.injector.trace
            h.holdUntil = Clock.now + 1
            await h.send(name, from: p)
            await InertTask.drain()
            check(h.gestureChords.open == .missionControl && !h.gestureChords.repeated, "대기 제스처가 기존 열린 상태 보존 " + name)
            Clock.now += 2
            h.releaseHeldInput()
            check(h.injector.trace == trace && h.gestureChords.open == .missionControl && !h.gestureChords.repeated, "만료 제스처가 기존 열린 상태 보존 " + name)
        }
    }
    do {
        let (h, p) = fresh()
        await h.send(from: p)
        await InertTask.drain()
        await h.send(from: p)
        await InertTask.drain()
        let trace = h.injector.trace
        await h.send("invalid", from: p)
        await InertTask.drain()
        check(h.injector.trace == trace && h.gestureChords.open == .missionControl && h.gestureChords.repeated, "잘못된 이름이 기존 repeated 상태 보존")
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
    do {
        let (h, p) = fresh()
        await h.send(from: p)
        h.onHotKeys = { h.gestureDrain?.cancel() }
        await InertTask.drain()
        pristine(h, "최종 단축키 조회 중 drain 취소")
    }
    await selectionChecks()
    check(InertTask.pending.isEmpty, "소유한 inert 작업 종료")
    print("\(Results.failures == 0 ? "PASS" : "FAIL") \(Results.assertions) assertions, \(Results.failures) failures; inert dependencies only")
}
@main struct GestureDrainChecks {
    @MainActor static func main() async {
        await checks()
        if Results.failures != 0 { exit(1) }
    }
}
