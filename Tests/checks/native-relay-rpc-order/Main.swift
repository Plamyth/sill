import Foundation
import StreamProtocol

@MainActor final class Fixture {
    let child = Process()
    let registry = LocalAudioParticipantRegistry()
    let log: URL
    let relay: LocalAudioRelay
    var bootstrapNativeCalls = 0
    static var number = 0

    init(_ mode: String) {
        Self.number += 1
        log = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("child-\(Self.number).jsonl")
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [CommandLine.arguments[1], mode, log.path]
        relay = LocalAudioRelay(participants: registry, process: child,
            packagedRuntime: .init(python: "inert-python", router: "inert-router", port: 0), forwarding: true,
            validateLaunch: { true })
        registry.register(.native, bootId: UUID(), control: .init(fenceAndQuiesce: { [weak self] request in
            self?.bootstrapNativeCalls += 1
            return .init(request, state: .unknown, facts: .unknown)
        }, inspect: { [weak self] _ in
            self?.bootstrapNativeCalls += 1
            return nil
        }, supportsForwarding: true, forwardingPrepare: { [weak self] preparation in
            self?.bootstrapNativeCalls += 1
            return .init(preparation.request, state: .quiescent,
                facts: .init(admissionFenced: true, startsSettled: true, mediaDetached: true,
                             callbacksDrained: true, buffersEmpty: true, workersExited: true))
        }))
    }
    static func make(_ mode: String = "valid") async -> Fixture {
        let f = Fixture(mode)
        let started = await f.relay.start()
        precondition(started)
        return f
    }
    func finish() {
        relay.lost()
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        precondition(!child.isRunning && relay.checkDrained)
    }
    func requests() -> [[String: Any]] {
        (try! String(contentsOf: log, encoding: .utf8)).split(separator: "\n").map {
            try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func binding() async -> AudioForwardingBinding {
        guard case .accepted = await relay.forwardingConfigure(privacyGeneration: UUID()),
              case .accepted(let snapshot) = await relay.forwardingSnapshot(), let binding = snapshot.binding else {
            fatalError("binding fixture")
        }
        return binding
    }
}

@main struct Checks {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ value: Bool, _ message: String) {
        assertions += 1
        precondition(value, message)
    }
    @MainActor static func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "test barrier expired")
    }
    @MainActor static func main() async {
        if CommandLine.arguments.last == "bootstrap" {
            await bootstrap()
            print("bootstrap 검사 \(assertions)개 통과. 실제 등록 relay의 비공개 파이프와 inert 자식만 사용.")
            return
        }
        if CommandLine.arguments.last == "registered" {
            await registeredPreparation()
            print("PASS \(assertions) registered forwarding assertions. Actual private pipe, inert child only.")
            return
        }
        if CommandLine.arguments.last == "conflict" {
            await preparationConflict()
            print("PASS \(assertions) conflict receipt assertions. Actual private pipe, inert child only.")
            return
        }
        if CommandLine.arguments.last != "http-admission" {
            await fifo()
            await queuedCancellationAndDeadline()
            await acquiredCancellation()
            await registryCallers()
            await finalAdmission()
            await activeFailure()
            await lostDrain()
            await invalidReplies()
            await sequenceLimit()
            await prepare()
        }
        await httpPreparation()
        await reentrantAdmission()
        await preparationConflict()
        await registeredPreparation()
        if CommandLine.arguments.count == 3 {
            await bootstrap()
            await requestScope()
        }
        print("PASS \(assertions) assertions. Actual LocalAudioRelay private call, inert stdio only.")
    }
    @MainActor static func requestIntent(_ peer: AudioForwardingPairedDevice,
                                         transport: AudioForwardingTransport = .native) -> AudioForwardingIntentRequest {
        try! AudioForwardingIntentRequest(pairedDeviceId: peer.id, intentId: UUID(), intentRevision: .init(7),
            action: .request, inputDesired: true, outputDesired: false, expectedRevision: .init(9),
            transportId: UUID(), transportKind: transport, bindingRevision: .init(11))
    }
    @MainActor static func requestCredential(_ peer: AudioForwardingPairedDevice) -> AudioForwardingCredential {
        try! AudioForwardingCredential(pairedDeviceId: peer.id, pairingGeneration: peer.pairingGeneration,
            credential: String(repeating: "a", count: 43))
    }
    @MainActor static func requestFrames(_ f: Fixture, peer: AudioForwardingPairedDevice,
                                         intent: AudioForwardingIntentRequest, count: Int) {
        let requests = f.requests(), calls = requests.filter { $0["method"] as? String == "forwardingRequest" }
        expect(calls.count == count, "실제 forwardingRequest 전송 횟수")
        for call in calls {
            let payload = call["payload"] as! [String: Any], submitted = payload["intent"] as! [String: Any]
            expect(Set(payload.keys) == ["pairedDeviceId", "credential", "intent"], "요청 payload는 정확히 3개 필드만 전송")
            expect(payload["pairedDeviceId"] as? String == peer.id.hex &&
                   payload["credential"] as? String == String(repeating: "a", count: 43), "확인된 peer와 credential만 전송")
            expect(Set(submitted.keys) == ["schemaVersion", "pairedDeviceId", "intentId", "intentRevision", "action",
                "inputDesired", "outputDesired", "expectedRevision", "transportId", "transportKind", "bindingRevision"],
                "intent는 기존 11개 필드 계약을 유지")
            let decoded = try! JSONDecoder().decode(AudioForwardingIntentRequest.self,
                from: JSONSerialization.data(withJSONObject: submitted))
            expect(decoded == intent, "실제 파이프의 intent는 제출한 모든 값과 동일")
        }
        expect(requests.map { $0["sequence"] as! String } == (1...requests.count).map(String.init), "요청 FIFO 순번은 연속")
        expect(Set(requests.map { $0["requestId"] as! String }).count == requests.count, "요청마다 고유한 requestId 사용")
        expect(f.bootstrapNativeCalls == 0, "요청 검사는 native 준비·차단·검사 콜백을 실행하지 않음")
        let allowed = Set(["bootstrap", "inspectRuntime", "forwardingRequest", "hold", "after-request"])
        expect(requests.allSatisfy { allowed.contains($0["method"] as! String) }, "요청 검사는 미디어 준비·commit RPC를 보내지 않음")
    }
    @MainActor static func requestSnapshot(_ snapshot: AudioForwardingSnapshot, intent: AudioForwardingIntentRequest) {
        expect(snapshot.revision.value == 12 && snapshot.binding == nil, "요청 응답의 snapshot revision과 미연결 상태 보존")
        expect(snapshot.intent?.pairedDeviceId == intent.pairedDeviceId && snapshot.intent?.intentId == intent.intentId &&
               snapshot.intent?.intentRevision == intent.intentRevision, "요청 응답의 intent 소유자·ID·revision 보존")
        expect(snapshot.intent?.inputDesired == intent.inputDesired && snapshot.intent?.outputDesired == intent.outputDesired &&
               snapshot.intent?.sentryDesired == true && snapshot.intent?.localMutedDesired == true,
               "요청 응답의 입력·출력과 보호 조건 보존")
    }
    @MainActor static func requestScope() async {
        await requestAcceptedAndRefused()
        await requestEntryScope()
        await requestAdmission()
    }
    @MainActor static func requestAcceptedAndRefused() async {
        for scenario in ["accepted", "refused"] {
            let f = await Fixture.make("request-\(scenario)"), peer = bootstrapPeer()
            let intent = requestIntent(peer), credential = requestCredential(peer), membership = f.registry.snapshot
            var checks = 0
            for observation in 1...2 {
                let result = observation == 1
                    ? await f.relay.forwardingRequest(intent, peer: peer, credential: credential)
                    : await f.relay.forwardingRequest(intent, peer: peer, credential: credential,
                        admission: { checks += 1; return true })
                if scenario == "accepted" {
                    guard case .accepted(let snapshot) = result else { fatalError("현재 scope의 정상 요청은 accepted 반환") }
                    requestSnapshot(snapshot, intent: intent)
                } else {
                    guard case .refused(let code, let snapshot) = result else { fatalError("요청의 typed refused 유지") }
                    expect(code == "stale_revision", "typed refused의 오류 코드 보존")
                    requestSnapshot(snapshot, intent: intent)
                }
                expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.snapshot == membership,
                       "정상 요청과 typed refused는 연결·FIFO·membership 보존")
                requestFrames(f, peer: peer, intent: intent, count: observation)
            }
            expect(checks >= 2, "요청 admission은 송신 직전과 응답 전달 직전에 재평가")
            expect(await f.relay.checkedCall("after-request", until: .now.advanced(by: .seconds(1))) == 1,
                   "정상 요청과 typed refused 이후 같은 자식에 다음 RPC 가능")
            f.finish()
        }
    }
    @MainActor static func requestEntryScope() async {
        for scenario in ["registered-boot", "registry", "http", "intent-peer", "credential-peer", "credential-generation", "gate"] {
            let f = await Fixture.make("request-accepted"), peer = bootstrapPeer()
            let other = AudioForwardingPairedDevice(id: AudioForwardingDeviceID(hex: String(repeating: "cd", count: 32))!,
                pairingGeneration: UUID())
            let intent = requestIntent(scenario == "intent-peer" ? other : peer, transport: scenario == "http" ? .http : .native)
            let credentialPeer = scenario == "credential-peer" ? other : scenario == "credential-generation"
                ? AudioForwardingPairedDevice(id: peer.id, pairingGeneration: UUID()) : peer
            let credential = requestCredential(credentialPeer)
            if scenario == "registered-boot" { f.relay.checkReplaceConnectedBoot() }
            if scenario == "registered-boot" || scenario == "registry" {
                f.registry.register(.relay, bootId: scenario == "registered-boot" ? f.relay.checkBootstrapBoot! : UUID(),
                    control: .init(fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
            }
            let membership = f.registry.snapshot, boot = f.relay.checkBootstrapBoot
            let registeredBoot = f.relay.checkBootstrapRegisteredBoot, sequence = f.relay.checkSequence, count = f.requests().count
            var checks = 0
            expect(await f.relay.forwardingRequest(intent, peer: peer, credential: credential,
                admission: { checks += 1; return scenario != "gate" }) == nil, "진입 시 \(scenario) 불일치 요청 거절")
            expect(f.requests().count == count && f.relay.checkSequence == sequence, "진입 거절은 전송·순번 소비 없음 \(scenario)")
            expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.snapshot == membership &&
                   f.relay.checkBootstrapBoot == boot && f.relay.checkBootstrapRegisteredBoot == registeredBoot,
                   "진입 거절은 현재 연결·등록 boot·새 registry 보존 \(scenario)")
            expect(scenario == "gate" ? checks >= 1 : checks == 0, "잘못된 진입은 admission 호출 전에 거절 \(scenario)")
            requestFrames(f, peer: peer, intent: intent, count: 0)
            f.finish()
            if scenario == "registered-boot" || scenario == "registry" {
                expect(f.registry.snapshot == membership, "이전 객체 종료가 새 relay 등록을 해제하지 않음")
            }
        }
    }
    @MainActor static func requestAdmission() async {
        for queued in [true, false] {
            for mutation in ["gate", "boot", "membership", "registry"] {
                let f = await Fixture.make("request-delayed"), peer = bootstrapPeer()
                let intent = requestIntent(peer), credential = requestCredential(peer), sequence = f.relay.checkSequence
                var admitted = true, checks = 0
                let hold: Task<Int?, Never>? = queued
                    ? Task { await f.relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) } : nil
                if queued { await wait { f.relay.checkPending } }
                let submission = Task { await f.relay.forwardingRequest(intent, peer: peer, credential: credential,
                    admission: { checks += 1; return admitted }) }
                if queued {
                    await wait { f.relay.checkWaiting == 1 }
                    expect(checks == 0, "요청 admission은 FIFO 슬롯 획득 이후 실행")
                } else {
                    await wait { f.requests().last?["method"] as? String == "forwardingRequest" }
                    expect(checks >= 1 && f.relay.checkPending, "송신 전 admission을 통과한 요청 응답 대기 상태")
                }
                if mutation == "gate" { admitted = false }
                else if mutation == "boot" { f.relay.checkReplaceConnectedBoot() }
                else if mutation == "membership" { f.registry.unregister(.native) }
                else {
                    f.registry.register(.relay, bootId: UUID(),
                        control: .init(fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
                }
                let membership = f.registry.snapshot, boot = f.relay.checkBootstrapBoot
                let registeredBoot = f.relay.checkBootstrapRegisteredBoot
                expect(await submission.value == nil, "대기 중 \(mutation) 변경 시 이전 요청 결과 전달 금지")
                if queued { expect(await hold?.value == 1, "요청 scope 변경이 선행 RPC를 닫지 않음") }
                expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.snapshot == membership &&
                       f.relay.checkBootstrapBoot == boot && f.relay.checkBootstrapRegisteredBoot == registeredBoot,
                       "이전 요청 폐기는 현재 연결·등록 boot·새 membership 보존")
                expect(f.relay.checkSequence == sequence + 1, "scope 변경은 미전송 요청의 순번을 소비하거나 추가 RPC를 보내지 않음")
                if !queued && mutation == "gate" { expect(checks >= 2, "응답 대기 중 권한 철회를 반환 전에 재검사") }
                requestFrames(f, peer: peer, intent: intent, count: queued ? 0 : 1)
                if mutation != "boot" {
                    expect(await f.relay.checkedCall("after-request", until: .now.advanced(by: .seconds(1))) == 1,
                           "이전 요청 결과 폐기 후에도 같은 자식의 파이프 사용 가능")
                }
                f.finish()
                if mutation == "registry" { expect(f.registry.snapshot == membership, "이전 객체 정리가 교체된 relay 등록을 보존") }
            }
        }
    }
    @MainActor static func bootstrapFixture(_ scenario: String) async -> Fixture {
        let f = await Fixture.make("bootstrap-\(scenario)")
        guard case .accepted = await f.relay.forwardingConfigure(privacyGeneration: UUID()) else {
            fatalError("bootstrap 구성 실패")
        }
        return f
    }
    @MainActor static func bootstrapPeer() -> AudioForwardingPairedDevice {
        AudioForwardingPairedDevice(id: AudioForwardingDeviceID(hex: String(repeating: "ab", count: 32))!, pairingGeneration: UUID())
    }
    @MainActor static func bootstrapFrames(_ f: Fixture, peer: AudioForwardingPairedDevice, count: Int) {
        let requests = f.requests()
        let calls = requests.filter { $0["method"] as? String == "forwardingBootstrap" }
        expect(calls.count == count, "실제 bootstrap 전송 횟수")
        for call in calls {
            let payload = call["payload"] as! [String: Any]
            expect(Set(payload.keys) == ["pairedDeviceId", "pairingGeneration"], "bootstrap payload에는 기기 ID와 세대만 포함")
            expect(payload["pairedDeviceId"] as? String == peer.id.hex &&
                   (payload["pairingGeneration"] as? String).flatMap({ UUID(uuidString: $0) }) == peer.pairingGeneration,
                   "호스트가 확인한 peer의 ID와 세대를 그대로 전송")
        }
        expect(requests.map { $0["sequence"] as! String } == (1...requests.count).map(String.init), "bootstrap FIFO 순번은 연속")
        expect(Set(requests.map { $0["requestId"] as! String }).count == requests.count, "관측마다 고유한 requestId 사용")
        expect(f.bootstrapNativeCalls == 0, "관측은 native 참여자의 준비·차단·검사를 실행하지 않음")
        let allowed = Set(["bootstrap", "inspectRuntime", "forwardingConfigure", "forwardingBootstrap", "after-bootstrap",
                           "hold", "hold-bootstrap-deadline"])
        expect(requests.allSatisfy { allowed.contains($0["method"] as! String) }, "관측은 등록·요청·준비·commit 등 미디어 진입 RPC를 보내지 않음")
    }
    @MainActor static func bootstrap() async {
        await bootstrapAccepted()
        await bootstrapRegistryScope()
        await bootstrapInvalid()
        await bootstrapStale()
        await bootstrapRefused()
        await bootstrapQueuedCancellationAndDeadline()
        await bootstrapAdmission()
    }
    @MainActor static func bootstrapRegistryScope() async {
        let stale = await bootstrapFixture("empty"), peer = bootstrapPeer(), replacement = UUID()
        stale.registry.register(.relay, bootId: replacement,
            control: .init(fenceAndQuiesce: { .init($0, state: .unknown, facts: .unknown) }, inspect: { _ in nil }))
        let current = stale.registry.snapshot
        expect(await stale.relay.forwardingBootstrap(peer: peer) == nil, "교체된 이전 relay는 bootstrap을 전송하지 않음")
        expect(stale.relay.checkConnected && stale.registry.snapshot == current && current.boots[.relay] == replacement,
               "이전 객체의 관측 거절은 새 relay 등록을 보존")
        bootstrapFrames(stale, peer: peer, count: 0)
        stale.finish()
        expect(stale.registry.snapshot == current, "이전 객체 종료가 새 relay 등록을 해제하지 않음")

        let observing = await bootstrapFixture("empty")
        observing.registry.unregister(.native)
        let incomplete = observing.registry.snapshot
        guard case .accepted = await observing.relay.forwardingBootstrap(peer: peer) else {
            fatalError("현재 relay의 관측은 native 미디어 준비를 요구하지 않음")
        }
        expect(observing.relay.checkConnected && observing.registry.snapshot == incomplete,
               "native가 준비되지 않아도 관측은 현 상태만 반환")
        bootstrapFrames(observing, peer: peer, count: 1)
        observing.finish()
    }
    @MainActor static func bootstrapAccepted() async {
        for scenario in ["empty", "max-cursor", "own-off", "own-off-binding", "other-off", "other-active"] {
            let f = scenario == "empty" || scenario == "max-cursor"
                ? await Fixture.make("bootstrap-\(scenario)") : await bootstrapFixture(scenario)
            let peer = bootstrapPeer()
            let membership = f.registry.snapshot
            var checks = 0
            var original: Data?
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for observation in 1...4 {
                let result = scenario == "empty"
                    ? await f.relay.forwardingBootstrap(peer: peer)
                    : await f.relay.forwardingBootstrap(peer: peer, admission: { checks += 1; return true })
                guard case .accepted(let bootstrap) = result else { fatalError("정상 bootstrap 응답 거절 \(scenario)") }
                expect(bootstrap.credential.pairedDeviceId == peer.id && bootstrap.credential.pairingGeneration == peer.pairingGeneration &&
                       bootstrap.credential.credential == String(repeating: "a", count: 43), "accepted credential의 기기·세대·값 보존")
                let expectedIntent: UInt64 = scenario == "empty" ? 0 : scenario == "max-cursor" ? UInt64.max : 7
                let expectedBinding: UInt64 = scenario == "empty" ? 0 : scenario == "max-cursor" ? UInt64.max : 11
                expect(bootstrap.ownCursor.intentRevision.value == expectedIntent && bootstrap.ownCursor.bindingRevision.value == expectedBinding,
                       "자기 cursor의 0·일반값·UInt64 최댓값 보존")
                expect(bootstrap.snapshot.revision.value == 9, "공유 snapshot revision 보존")
                if scenario == "empty" || scenario == "max-cursor" {
                    expect(bootstrap.snapshot.intent == nil && bootstrap.snapshot.binding == nil, "기억 없는 관측은 미디어 binding을 만들지 않음")
                } else {
                    let other = scenario.hasPrefix("other-"), active = scenario == "other-active"
                    let owner = other ? AudioForwardingDeviceID(hex: String(repeating: "cd", count: 32))! : peer.id
                    let intent = bootstrap.snapshot.intent, binding = bootstrap.snapshot.binding
                    expect(intent?.pairedDeviceId == owner, "자기 기기와 다른 기기의 기억 상태를 구별")
                    expect(intent?.intentRevision.value == (other ? 99 : 7), "다른 기기의 공유 intent revision을 자기 cursor로 대체하지 않음")
                    expect(intent?.inputDesired == active && intent?.outputDesired == active,
                           "기억된 OFF 또는 다른 기기의 active 상태를 그대로 관측")
                    if scenario == "own-off-binding" || active {
                        expect(binding?.pairedDeviceId == owner && binding?.phase == (active ? .active : .off), "기억된 binding의 소유자와 상태 보존")
                    } else { expect(binding == nil, "연결이 없는 기억 상태의 관측은 binding을 생성하지 않음") }
                    expect(intent?.sentryDesired == true && intent?.localMutedDesired == true, "기억 상태의 보호 조건 보존")
                }
                let data = try! encoder.encode(bootstrap)
                if let original { expect(data == original, "반복 관측은 credential·cursor·snapshot을 변경하지 않음") }
                else { original = data }
                expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.matches(membership), "반복 관측은 연결·등록 boot·membership 보존")
                bootstrapFrames(f, peer: peer, count: observation)
            }
            if scenario != "empty" { expect(checks >= 8, "순수 admission 검사를 전송 전과 응답 전달 전에 재평가") }
            f.finish()
        }
    }
    @MainActor static func bootstrapInvalid() async {
        var scenarios = ["credential-id", "credential-generation", "cursor-mismatch", "extra", "credential-extra", "credential-invalid", "cursor-extra"]
        scenarios += ["credential", "ownCursor", "snapshot"].map { "missing-\($0)" }
        scenarios += ["pairedDeviceId", "pairingGeneration", "credential"].map { "credential-missing-\($0)" }
        scenarios += ["intentRevision", "bindingRevision"].map { "cursor-missing-\($0)" }
        for field in ["intentRevision", "bindingRevision"] {
            scenarios += ["number", "boolean", "fraction", "null", "object", "array", "empty", "negative", "plus", "leading", "overflow",
                          "whitespace", "exponent", "decimal"].map { "cursor-invalid-\(field)-\($0)" }
        }
        scenarios += ["missing-schemaVersion", "missing-revision", "missing-intent", "missing-binding", "extra", "schema", "revision",
                      "intent-revision", "intent-protection", "binding-owner", "binding-generation", "binding-active-off",
                      "binding-without-intent", "binding-configuration"].map { "bad-snapshot-\($0)" }
        for scenario in scenarios {
            let f = await bootstrapFixture(scenario), peer = bootstrapPeer()
            let nativeBoot = f.registry.snapshot.boots[.native]
            expect(await f.relay.forwardingBootstrap(peer: peer) == nil, "불일치 또는 잘못된 bootstrap 거절 \(scenario)")
            expect(f.relay.checkClosed && f.relay.checkDrained, "잘못된 bootstrap은 연결을 닫고 FIFO를 정리 \(scenario)")
            expect(f.registry.snapshot.boots[.relay] == nil && f.registry.snapshot.boots[.native] == nativeBoot,
                   "실패한 relay 등록만 해제 \(scenario)")
            bootstrapFrames(f, peer: peer, count: 1)
            f.finish()
        }
    }
    @MainActor static func bootstrapStale() async {
        for field in ["requestId", "sequence", "relayBootId", "controllerBootId"] {
            let f = await bootstrapFixture("stale-\(field)"), peer = bootstrapPeer()
            guard case .accepted = await f.relay.forwardingBootstrap(peer: peer) else { fatalError("stale 전 정상 관측 실패") }
            expect(await f.relay.forwardingBootstrap(peer: peer) == nil, "stale bootstrap envelope 거절 \(field)")
            expect(f.relay.checkClosed && f.relay.checkDrained && f.registry.snapshot.boots[.relay] == nil,
                   "stale envelope는 기존 fail-closed 적용 \(field)")
            bootstrapFrames(f, peer: peer, count: 2)
            f.finish()
        }
    }
    @MainActor static func bootstrapRefused() async {
        let f = await bootstrapFixture("refused"), peer = bootstrapPeer(), membership = f.registry.snapshot
        guard case .refused(let code, let snapshot) = await f.relay.forwardingBootstrap(peer: peer) else {
            fatalError("typed refused가 유지되어야 함")
        }
        expect(code == "remembered_device_superseded" && snapshot.intent?.pairedDeviceId.hex == String(repeating: "cd", count: 32) &&
               snapshot.intent?.intentRevision.value == 99 && snapshot.binding?.phase == .off, "typed refused의 코드와 snapshot을 그대로 반환")
        expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.matches(membership), "typed refused는 현재 연결과 membership 보존")
        expect(await f.relay.checkedCall("after-bootstrap", until: .now.advanced(by: .seconds(1))) == 1, "typed refused 이후 같은 자식에 다음 RPC 가능")
        bootstrapFrames(f, peer: peer, count: 1)
        f.finish()
    }
    @MainActor static func bootstrapQueuedCancellationAndDeadline() async {
        for cancel in [true, false] {
            let f = await bootstrapFixture("empty"), peer = bootstrapPeer(), membership = f.registry.snapshot
            if cancel {
                let preCancelled = Task { await f.relay.forwardingBootstrap(peer: peer) }
                preCancelled.cancel()
                expect(await preCancelled.value == nil && f.relay.checkConnected, "미리 취소된 bootstrap은 전송하지 않음")
                bootstrapFrames(f, peer: peer, count: 0)
            }
            let sequence = f.relay.checkSequence
            let hold = Task { await f.relay.checkedCall(cancel ? "hold" : "hold-bootstrap-deadline", until: .now.advanced(by: .seconds(5))) }
            await wait { f.relay.checkPending }
            let queued = Task { await f.relay.forwardingBootstrap(peer: peer) }
            await wait { f.relay.checkWaiting == 1 }
            if cancel { queued.cancel() }
            expect(await queued.value == nil, "큐의 bootstrap은 취소 또는 자체 3초 deadline에 nil 반환")
            expect(f.relay.checkConnected && f.relay.checkPending && f.relay.checkWaiting == 0 && f.relay.checkSequence == sequence + 1,
                   "미전송 bootstrap의 취소·만료는 활성 호출·연결·순번 보존")
            bootstrapFrames(f, peer: peer, count: 0)
            let survivor = Task { await f.relay.forwardingBootstrap(peer: peer) }
            await wait { f.relay.checkWaiting == 1 }
            expect(await hold.value == 1, "기존 활성 RPC는 bootstrap 취소·만료 이후 완료")
            guard case .accepted = await survivor.value else { fatalError("다음 bootstrap은 FIFO 슬롯을 받아야 함") }
            expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.matches(membership), "살아남은 bootstrap은 같은 연결로 완료")
            bootstrapFrames(f, peer: peer, count: 1)
            f.finish()
        }
    }
    @MainActor static func bootstrapAdmission() async {
        for queued in [true, false] {
            for mutation in ["gate", "boot", "membership"] {
                let f = await bootstrapFixture("delayed"), peer = bootstrapPeer()
                var admitted = true, checks = 0
                let hold: Task<Int?, Never>? = queued
                    ? Task { await f.relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) } : nil
                if queued { await wait { f.relay.checkPending } }
                let observation = Task { await f.relay.forwardingBootstrap(peer: peer, admission: { checks += 1; return admitted }) }
                if queued {
                    await wait { f.relay.checkWaiting == 1 }
                    expect(checks == 0, "bootstrap admission은 실제 FIFO 슬롯 획득 이후 검사")
                } else {
                    await wait { f.requests().last?["method"] as? String == "forwardingBootstrap" }
                    expect(checks >= 1 && f.relay.checkPending, "전송 전 admission을 통과한 응답 대기 상태")
                }
                if mutation == "gate" { admitted = false }
                else if mutation == "boot" { f.relay.checkBootstrapReplaceBoot(UUID()) }
                else { f.registry.unregister(.native) }
                let membership = f.registry.snapshot, boot = f.relay.checkBootstrapBoot, registeredBoot = f.relay.checkBootstrapRegisteredBoot
                expect(await observation.value == nil, "기다리는 동안 \(mutation) 변경 시 stale 결과 전달 금지")
                if queued { expect(await hold?.value == 1, "권한·boot·membership 변경이 선행 RPC를 닫지 않음") }
                expect(f.relay.checkConnected && f.relay.checkDrained && f.registry.snapshot == membership &&
                       f.relay.checkBootstrapBoot == boot && f.relay.checkBootstrapRegisteredBoot == registeredBoot,
                       "stale bootstrap은 변경된 현재 연결·등록 boot·membership을 보존")
                if !queued && mutation == "gate" { expect(checks >= 2, "응답 대기 중 권한 철회를 전달 전에 재검사") }
                bootstrapFrames(f, peer: peer, count: queued ? 0 : 1)
                if mutation != "boot" {
                    expect(await f.relay.checkedCall("after-bootstrap", until: .now.advanced(by: .seconds(1))) == 1,
                           "stale 결과 폐기 후에도 같은 자식의 RPC 연결 사용 가능")
                }
                f.finish()
            }
        }
    }
    @MainActor static func registeredPreparation() async {
        for cancel in [false, true] {
            let f = await Fixture.make(), binding = await f.binding()
            let membership = f.registry.snapshot
            guard let ticket = f.registry.beginForwarding(epoch: binding.bindingEpoch, intentGeneration: binding.intentGeneration,
                operationId: binding.operationId, privacyGeneration: binding.configuration.privacyGeneration,
                membership: membership, identity: [binding.transportId.uuidString]) else { fatalError("registered forwarding capability missing") }
            let request = binding.participantRequest(for: .relay, budgetMilliseconds: 2000)!
            let hold: Task<Int?, Never>? = cancel ? Task { await f.relay.checkedCall("hold-registered", until: .now.advanced(by: .seconds(2))) } : nil
            if cancel { await wait { f.relay.checkPending } }
            let count = f.requests().filter { $0["method"] as? String == "forwardingPrepare" }.count
            let prepare = Task { await f.registry.prepareForwarding(ticket, request: request, until: .now.advanced(by: .seconds(2))) }
            if cancel {
                await wait { f.relay.checkWaiting == 1 }
                f.registry.cancelForwarding(ticket)
                expect(await hold?.value == 1, "existing private call survives cancelled binding")
            }
            let receipt = await prepare.value
            if cancel {
                expect(receipt == nil && f.relay.checkConnected && f.registry.matches(membership), "cancelled registered preparation preserves connection")
                expect(f.requests().filter { $0["method"] as? String == "forwardingPrepare" }.count == count,
                       "cancelled binding is not submitted after waiting for the slot")
            } else {
                expect(receipt?.proves(request) == true, "actual registered typed callback prepares the relay")
                let nativeRequest = binding.participantRequest(for: .native, budgetMilliseconds: 2000)!
                let nativeReceipt = await f.registry.prepareForwarding(ticket, request: nativeRequest, until: .now.advanced(by: .seconds(1)))
                expect(nativeReceipt?.proves(nativeRequest) == true, "both members are prepared before inspect")
                let inspected = await f.registry.inspectForwarding(ticket, request: request, until: .now.advanced(by: .seconds(1)))
                expect(inspected?.proves(request) == true, "registered inspect confirms the same prepared relay")
                expect(f.relay.checkConnected && f.registry.matches(membership), "registered preparation preserves boot and membership")
            }
            f.finish()
        }
    }
    @MainActor static func preparationConflict() async {
        for field in ["valid", "operationId", "privacyGeneration", "bootId", "registryRevision", "schemaVersion", "participantId", "state", "reason", "facts"] {
            let f = await Fixture.make("conflict-\(field)"), binding = await f.binding()
            let original = binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!
            guard case .accepted(let prepared) = await f.relay.forwardingPrepare(binding) else { fatalError("conflict fixture prepare") }
            let stale = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(),
                privacyGeneration: original.privacyGeneration, registryRevision: original.registryRevision,
                participantId: .relay, bootId: original.bootId, budgetMilliseconds: 5000)
            let membership = f.registry.snapshot
            let refusal = await f.registry.checkedFence(stale)
            if field == "valid" {
                expect(refusal?.state == .blocked && refusal?.reason == "audio_preparation_conflict", "known conflict returns typed refusal")
                expect(f.relay.checkConnected && f.registry.matches(membership), "known conflict preserves connection and membership")
                expect(await f.registry.checkedInspect(binding.operationId) == prepared, "known conflict preserves previously prepared binding")
                expect(await f.relay.checkedCall("after-conflict", until: .now.advanced(by: .seconds(1))) == 1, "same child accepts the next RPC")
            } else {
                expect(f.relay.checkClosed, "invalid conflict receipt closes connection \(field)")
            }
            f.finish()
        }
    }
    @MainActor static func httpPreparation() async {
        for mode in ["valid", "http", "http-receipt-bootId", "http-receipt-registryRevision", "http-receipt-privacyGeneration"] {
            let f = await Fixture.make(mode), binding = await f.binding()
            expect(binding.transportKind == (mode == "valid" ? .native : .http), "fixture transport")
            let expected = binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!
            let membership = f.registry.snapshot
            let result = await f.relay.forwardingPrepare(binding)
            if mode == "valid" || mode == "http" {
                guard case .accepted(let receipt) = result else { fatalError("HTTP and native prepare must accept matching relay receipt") }
                expect(receipt.proves(expected) && f.registry.matches(membership), "prepare proves boot, configuration and membership")
                let inspected = await f.registry.checkedInspect(binding.operationId)
                expect(inspected == receipt && inspected?.proves(expected) == true, "inspect returns the same prepared receipt")
                expect(f.relay.checkConnected, "HTTP preparation preserves connection")
                if mode == "http" {
                    let count = f.requests().count, sequence = f.relay.checkSequence
                    let peer = AudioForwardingPairedDevice(id: binding.pairedDeviceId, pairingGeneration: UUID())
                    let credential = try! JSONDecoder().decode(AudioForwardingCredential.self, from: JSONSerialization.data(withJSONObject: [
                        "pairedDeviceId": binding.pairedDeviceId.hex, "pairingGeneration": peer.pairingGeneration.uuidString,
                        "credential": String(repeating: "a", count: 43)]))
                    let intent = try! JSONDecoder().decode(AudioForwardingIntentRequest.self, from: JSONSerialization.data(withJSONObject: [
                        "schemaVersion": 1, "pairedDeviceId": binding.pairedDeviceId.hex, "intentId": UUID().uuidString,
                        "intentRevision": "1", "action": "request", "inputDesired": true, "outputDesired": true,
                        "expectedRevision": "0", "transportId": binding.transportId.uuidString, "transportKind": "http", "bindingRevision": "1"]))
                    expect(await f.relay.forwardingRequest(intent, peer: peer, credential: credential) == nil, "HTTP intent submission remains prohibited")
                    expect(f.requests().count == count && f.relay.checkSequence == sequence, "HTTP intent request is not sent")
                }
            } else {
                expect(result == nil && f.relay.checkClosed, "HTTP preparation rejects mismatched receipt identity")
            }
            f.finish()
        }
    }
    @MainActor static func reentrantAdmission() async {
        for mutation in ["lost", "boot", "phase", "slot", "process"] {
            let f = await Fixture.make(), relay = f.relay
            let sequence = relay.checkSequence, count = f.requests().count
            var completed = false
            let request = Task {
                let result = await relay.checkedCall("reentrant-\(mutation)", until: .now.advanced(by: .seconds(1)), admission: {
                    switch mutation {
                    case "lost": relay.lost()
                    case "boot": relay.checkReplaceConnectedBoot()
                    case "phase": relay.checkReplacePhase()
                    case "slot": relay.checkReplaceSlot()
                    default:
                        f.child.terminate()
                        f.child.waitUntilExit()
                    }
                    return true
                })
                completed = true
                return result
            }
            await wait { completed }
            expect(await request.value == nil, "reentrant admission rejects before send \(mutation)")
            expect(relay.checkSequence == sequence && !relay.checkPending, "reentry consumes no sequence or pending continuation \(mutation)")
            expect(f.requests().count == count, "child receives no reentrant frame \(mutation)")
            f.finish()
        }
    }
    @MainActor static func fifo() async {
        let f = await Fixture.make(), relay = f.relay
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkPending }
        var queued: [Task<Int?, Never>] = []
        for i in 0..<12 {
            queued.append(Task { await relay.checkedCall("fifo-\(i)", until: .now.advanced(by: .seconds(3))) })
            await wait { relay.checkWaiting == i + 1 }
        }
        expect(await first.value == 1, "original overlapped call survives")
        for task in queued { expect(await task.value == 1, "queued call succeeds") }
        let calls = f.requests()
        expect(calls.map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold"] + (0..<12).map { "fifo-\($0)" }, "FIFO order")
        expect(calls.map { $0["sequence"] as! String } == (1...15).map(String.init), "contiguous sequence")
        expect(Set(calls.map { $0["requestId"] as! String }).count == calls.count, "unique request IDs")
        expect(relay.checkConnected && !relay.checkPending && relay.checkWaiting == 0, "valid overlap stays connected")
        f.finish()
    }
    @MainActor static func queuedCancellationAndDeadline() async {
        let f = await Fixture.make(), relay = f.relay
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkPending }
        let cancelled = Task { await relay.checkedCall("cancelled", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkWaiting == 1 }
        let expired = Task { await relay.checkedCall("expired", until: .now.advanced(by: .milliseconds(40))) }
        await wait { relay.checkWaiting == 2 }
        let survivor = Task { await relay.checkedCall("survivor", until: .now.advanced(by: .seconds(3))) }
        await wait { relay.checkWaiting == 3 }
        cancelled.cancel()
        expect(await cancelled.value == nil, "cancelled waiter returns nil")
        expect(await expired.value == nil, "expired waiter returns nil")
        expect(relay.checkConnected && relay.checkPending && relay.checkSequence == 3, "waiting failures preserve active request")
        let firstValue = await first.value, survivorValue = await survivor.value
        expect(firstValue == 1 && survivorValue == 1, "active and surviving waiter succeed")
        expect(f.requests().map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold", "survivor"], "no cancelled or expired frames")
        let past = await relay.checkedCall("past", until: .now.advanced(by: .seconds(-1)))
        expect(past == nil && relay.checkConnected && relay.checkSequence == 4, "already expired call is not sent")
        f.finish()
    }
    @MainActor static func acquiredCancellation() async {
        let f = await Fixture.make(), relay = f.relay
        let cancelled = Task { await relay.checkedCall("pre-cancelled", until: .now.advanced(by: .seconds(2))) }
        cancelled.cancel()
        expect(await cancelled.value == nil && relay.checkConnected && relay.checkSequence == 2, "pre-cancelled call is not sent")
        let first = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        let next = Task { await relay.checkedCall("cancel-before-grant", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 1 }
        next.cancel()
        expect(await next.value == nil, "cancellation removes waiter once")
        expect(await first.value == 1 && relay.checkConnected, "queued cancellation cannot close active child")
        let follow = await relay.checkedCall("follow", until: .now.advanced(by: .seconds(2)))
        expect(follow == 1 && relay.checkConnected, "late cancellation handler cannot close next call")
        f.finish()
    }
    @MainActor static func registryCallers() async {
        for cancelled in [false, true] {
            let f = await Fixture.make(), relay = f.relay
            let request = LocalAudioParticipantRequest(schemaVersion: 1, operationId: UUID(), privacyGeneration: UUID(),
                registryRevision: String(f.registry.snapshot.revision), participantId: .relay,
                bootId: f.registry.snapshot.boots[.relay]!, budgetMilliseconds: cancelled ? 2000 : 40)
            let hold = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
            await wait { relay.checkPending }
            let fence = Task { await f.registry.checkedFence(request) }
            await wait { relay.checkWaiting == 1 }
            if cancelled { fence.cancel() }
            let receipt = await fence.value
            expect(receipt?.state == .unknown, "queued registry fence returns unknown")
            expect(relay.checkConnected && relay.checkPending, "unsent registry fence must not close child")
            expect(await hold.value == 1, "registry fence does not close active call")
            expect(!f.requests().contains { $0["method"] as? String == "fenceAndQuiesce" }, "registry waiter not sent")
            let actual = await f.registry.checkedFence(request)
            expect(actual?.proves(request) == true, "registry fence still validates actual receipt")
            expect(await f.registry.checkedInspect(request.operationId) == nil && relay.checkConnected, "inspect uses shared pipe")
            f.finish()
        }
    }
    @MainActor static func finalAdmission() async {
        let f = await Fixture.make(), relay = f.relay
        var scopeIsCurrent = true, validations = 0
        let hold = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        let stale = Task { await relay.checkedCall("stale-commit", until: .now.advanced(by: .seconds(2)), admission: {
            validations += 1
            return scopeIsCurrent
        }) }
        await wait { relay.checkWaiting == 1 }
        expect(validations == 0, "admission waits for private pipe slot")
        scopeIsCurrent = false
        let next = Task { await relay.checkedCall("after-stale", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkWaiting == 2 }
        expect(await hold.value == 1, "in-flight request completes before admission")
        expect(await stale.value == nil, "stale coordinator scope rejects unsent request")
        expect(await next.value == 1, "admission refusal releases next FIFO slot")
        expect(validations == 1 && relay.checkConnected, "admission checked exactly once without closing")
        expect(f.requests().map { $0["method"] as! String } == ["bootstrap", "inspectRuntime", "hold", "after-stale"], "no stale frame or sequence gap")
        scopeIsCurrent = true
        let accepted = await relay.checkedCall("admitted", until: .now.advanced(by: .seconds(2)), admission: {
            validations += 1
            return scopeIsCurrent
        })
        expect(accepted == 1 && validations == 2 && relay.checkSequence == 5, "current proof permits one send")
        let expired = await relay.checkedCall("expired-proof", until: .now.advanced(by: .seconds(-1)), admission: {
            validations += 1
            return scopeIsCurrent
        })
        expect(expired == nil && validations == 2 && relay.checkConnected, "expired request does not validate or send")
        var cancellingProof: Task<Int?, Never>?
        cancellingProof = Task { await relay.checkedCall("cancel-in-proof", until: .now.advanced(by: .seconds(2)), admission: {
            cancellingProof?.cancel()
            return scopeIsCurrent
        }) }
        expect(await cancellingProof!.value == nil, "cancellation inside final proof is unsent")
        expect(relay.checkConnected && relay.checkSequence == 5, "final unsent cancellation preserves sequence and pipe")
        f.finish()
    }
    @MainActor static func activeFailure() async {
        for cancel in [true, false] {
            let f = await Fixture.make(), relay = f.relay
            let active = Task { await relay.checkedCall("hold", until: .now.advanced(by: cancel ? .seconds(2) : .milliseconds(60))) }
            await wait { relay.checkPending }
            let queued = Task { await relay.checkedCall("must-not-send", until: .now.advanced(by: .seconds(2))) }
            await wait { relay.checkWaiting == 1 }
            await wait { f.requests().last?["method"] as? String == "hold" }
            if cancel { active.cancel() }
            let activeValue = await active.value, queuedValue = await queued.value
            expect(activeValue == nil && queuedValue == nil, "sent cancel or timeout drains queue")
            expect(relay.checkClosed && relay.checkDrained, "sent failure is fail-closed")
            expect(f.requests().count == 3, "sent failure never sends queued successor")
            f.finish()
        }
    }
    @MainActor static func lostDrain() async {
        let f = await Fixture.make(), relay = f.relay
        let active = Task { await relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
        await wait { relay.checkPending }
        var queued: [Task<Int?, Never>] = []
        for i in 0..<8 {
            queued.append(Task { await relay.checkedCall("lost-\(i)", until: .now.advanced(by: .milliseconds(300))) })
            await wait { relay.checkWaiting == i + 1 }
        }
        relay.lost(); relay.lost()
        expect(await active.value == nil, "lost resolves active continuation")
        for task in queued { expect(await task.value == nil, "lost resolves queued continuation once") }
        try? await Task.sleep(for: .milliseconds(350))
        expect(relay.checkDrained && relay.checkClosed, "all waiter timers stay drained")
        expect(f.registry.snapshot.boots[.relay] == nil, "lost unregisters matching boot")
        f.finish()
    }
    @MainActor static func invalidReplies() async {
        for mode in ["schemaVersion", "sequence", "controllerBootId", "relayBootId", "requestId", "processId", "unknown", "duplicate", "bom", "oversize", "double", "invalid", "eof", "blank"] {
            let f = await Fixture.make(mode)
            expect(await f.relay.checkedCall("bad", until: .now.advanced(by: .seconds(2))) == nil, "reject \(mode)")
            expect(f.relay.checkClosed && f.relay.checkDrained, "invalid reply closes and drains \(mode)")
            f.finish()
        }
    }
    @MainActor static func sequenceLimit() async {
        let f = await Fixture.make()
        f.relay.checkSetSequence(UInt64.max)
        expect(await f.relay.checkedCall("overflow", until: .now.advanced(by: .seconds(2))) == nil, "sequence cannot wrap")
        expect(f.relay.checkClosed && f.requests().count == 2, "overflow closes before send")
        f.finish()
    }
    @MainActor static func prepare() async {
        for explicit in [true, false] {
            let f = await Fixture.make("slow-prepare")
            let binding = await f.binding()
            let peer = AudioForwardingPairedDevice(id: binding.pairedDeviceId, pairingGeneration: UUID())
            let registration = Task { await f.relay.forwardingRegister(peer) }
            await wait { f.relay.checkPending }
            let poll = Task { await f.relay.forwardingSnapshot() }
            await wait { f.relay.checkWaiting == 1 }
            let prepared = Task { explicit
                ? await f.relay.forwardingPrepare(binding, until: .now.advanced(by: .seconds(5)))
                : await f.relay.forwardingPrepare(binding) }
            await wait { f.relay.checkWaiting == 2 }
            guard case .accepted = await registration.value, case .accepted = await poll.value,
                  case .accepted(let receipt) = await prepared.value else { fatalError("prepare must survive 3s and overlapping callers") }
            expect(receipt.proves(binding.participantRequest(for: .relay, budgetMilliseconds: 5000)!), "prepare expected receipt")
            expect(f.relay.checkConnected, "prepare validates connected boot")
            let methods = f.requests().map { $0["method"] as! String }
            expect(Array(methods.suffix(3)) == ["forwardingRegister", "forwardingSnapshot", "forwardingPrepare"], "catalog, poll, prepare FIFO")
            f.finish()
        }
        for mode in ["receipt-operationId", "receipt-privacyGeneration", "receipt-registryRevision", "receipt-participantId", "receipt-bootId", "receipt-schemaVersion", "receipt-state", "receipt-facts"] {
            let f = await Fixture.make(mode), binding = await f.binding()
            expect(await f.relay.forwardingPrepare(binding) == nil, "prepare rejects \(mode)")
            expect(f.relay.checkClosed, "bad prepare receipt is fail-closed")
            f.finish()
        }
        for budget in [40, 0, -100] {
            let f = await Fixture.make(), binding = await f.binding()
            let hold = Task { await f.relay.checkedCall("hold", until: .now.advanced(by: .seconds(2))) }
            await wait { f.relay.checkPending }
            expect(await f.relay.forwardingPrepare(binding, until: .now.advanced(by: .milliseconds(budget))) == nil, "prepare retains absolute deadline")
            expect(await hold.value == 1 && f.relay.checkConnected, "untransmitted prepare deadline preserves connection")
            expect(!f.requests().contains { $0["method"] as? String == "forwardingPrepare" }, "expired prepare never sent")
            f.finish()
        }
        let combined = await Fixture.make("queued-over-prepare"), combinedBinding = await combined.binding()
        let peer = AudioForwardingPairedDevice(id: combinedBinding.pairedDeviceId, pairingGeneration: UUID())
        let registration = Task { await combined.relay.forwardingRegister(peer) }
        await wait { combined.requests().last?["method"] as? String == "forwardingRegister" }
        let prepared = await combined.relay.forwardingPrepare(combinedBinding, until: .now.advanced(by: .seconds(5)))
        guard case .accepted = await registration.value else { fatalError("long queue fixture registration") }
        expect(prepared == nil && combined.relay.checkClosed, "queue plus prepare cannot extend absolute 5s deadline")
        expect(combined.requests().last?["method"] as? String == "forwardingPrepare", "combined deadline expires after transmission")
        combined.finish()
        let capped = await Fixture.make("over-prepare"), binding = await capped.binding()
        expect(await capped.relay.forwardingPrepare(binding, until: .now.advanced(by: .seconds(20))) == nil, "prepare caps excessive supplied budget")
        expect(capped.relay.checkClosed, "prepare times out at maximum 5s")
        capped.finish()
    }
}
