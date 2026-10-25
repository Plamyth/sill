import Foundation
import StreamProtocol

@MainActor
func visionChecks() throws {
    let initialProfile = URL(fileURLWithPath: CommandLine.arguments[2])
    func client(_ memory: Memory) -> StreamClient {
        runtimeMemory = memory; Bundle.url = initialProfile
        DeviceIdentity.value = .init(privateKey: .init(Data(memory.binding.deviceSPKI.suffix(65))), fingerprint: memory.binding.deviceFingerprint)
        let stream = StreamClient()
        let peer = NWConnection(); peer.pin = memory.binding.hostPin
        stream.connection = peer; stream.session = .init(macID: memory.binding.macID)
        stream.savedMacs = [.init(macID: memory.binding.macID, fingerprintData: memory.binding.hostPin, homeTLS: true)]
        return stream
    }
    for mode in ["retired", "scene-background", "lease-missing", "test-bundle"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        switch mode {
        case "retired": stream.visionWindowRetired = true
        case "scene-background": stream.visionStartupForeground = false
        case "lease-missing": stream.visionDisplaySelection.lease = nil
        default: VisionReleaseTestContext.isTestBundle = true
        }
        stream.connected = true; stream.resumeOwnerEnrollment()
        try check(memory.requests.isEmpty && memory.raw == nil, "Vision 현재 창·scene·테스트 격리 거절 \(mode)")
        VisionReleaseTestContext.isTestBundle = false
    }
    for mode in ["lease", "retired", "peer", "device", "cancel", "foreground", "pin", "profile"] {
        let memory = try Memory(readbackGolden); memory.holdChallenge = true
        let stream = client(memory); stream.connected = true; stream.resumeOwnerEnrollment()
        try check(memory.requests.map(\.0) == [.challenge], "연결 준비 뒤 challenge만 발행")
        switch mode {
        case "lease": stream.visionDisplaySelection.lease = .init(window: UUID())
        case "retired": stream.visionWindowRetired = true
        case "peer": stream.connection = NWConnection()
        case "device": DeviceIdentity.value = nil
        case "cancel": stream.cancelOwnerEnrollment()
        case "foreground": stream.visionStartupForeground = false
        case "pin": stream.connection?.pin = Data(repeating: 9, count: 32)
        default: Bundle.url = nil
        }
        memory.parked?(memory.response(memory.fixture["challengeResponse"]!))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try check(memory.raw == nil && memory.receiptCalls == 0 && stream.ownerEnrollmentCredential == nil,
                  "Vision 늦은 challenge가 receipt·저장을 만들지 않음 \(mode)")
        stream.cancelOwnerEnrollment()
    }
    let scoped = try Memory(readbackGolden), stream = client(scoped)
    stream.connected = true; stream.resumeOwnerEnrollment()
    settle { stream.ownerEnrollmentCredential != nil }
    for (path, method) in [("/v1/catalog", "GET"), ("/v1/events?token=x", "GET"), ("/v1/send", "POST"), ("/v1/events", "POST")] {
        reject("Vision gateway 권한 확대 거절") { _ = try stream.ownerEnrollmentAuthorizedRequest(path: path, method: method) }
    }
    stream.visionDisplaySelection.lease = .init(window: UUID())
    reject("다른 창 lease에서 기존 bearer 사용 0") { _ = try stream.ownerEnrollmentAuthorizedRequest(path: "/v1/events", method: "GET") }
    stream.cancelOwnerEnrollment()

    for mode in ["same-peer", "peer-changed", "lease-changed", "retired", "cancel", "no-profile"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        var scheduled: [DispatchWorkItem] = []
        let events = ControlEventsController(stream: { _ in fatalError("숨긴 화면의 실제 네트워크 금지") })
        let control = VisionControlEnrollmentController(events: events, client: stream,
            now: { Double(memory.now) / 1000 }, schedule: { _, item in scheduled.append(item) })
        stream.connected = true; stream.resumeOwnerEnrollment()
        settle { stream.ownerEnrollmentCredential != nil }
        try check(events.configured && scheduled.count == 1 && control.registeredOrigin == P.origin, "생산 consumer가 자동 자격만 구성")
        let raw = memory.raw, requests = memory.requests.count
        memory.now = 1_800_086_400_001
        switch mode {
        case "peer-changed": stream.connection = NWConnection()
        case "lease-changed": stream.visionDisplaySelection.lease = .init(window: UUID())
        case "retired": stream.visionWindowRetired = true
        case "cancel": stream.cancelOwnerEnrollment()
        case "no-profile": Bundle.url = nil
        default: break
        }
        if mode == "same-peer" {
            memory.postHandler = { route, _ in
                if route == .readbackChallenge { return memory.response(503, .object(["error": .string("ENROLLMENT_PROVIDER_UNAVAILABLE")])) }
                fatalError("확정 만료 전 새 등록 금지")
            }
        }
        scheduled[0].perform()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if mode == "same-peer" {
            try check(memory.requests.count == requests + 1 && memory.requests.last?.0 == .readbackChallenge,
                      "401 이벤트·foreground 없이 로컬 만료가 기존 pending readback 한 번 재개")
        } else {
            try check(memory.requests.count == requests && memory.raw == raw, "만료 뒤 현재성 변경은 등록·저장 0 \(mode)")
        }
        try check(!events.configured && scheduled.count == 1, "만료·거절 뒤 타이머 무한 반복 없음")
        stream.cancelOwnerEnrollment()
    }
    for mode in ["401-renew", "403", "stale-peer", "stale-lease", "cancel", "wrong-request"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        var gateways: [ControlEventsGateway] = []
        var continuations: [AsyncThrowingStream<ControlEventsStreamItem, Error>.Continuation] = []
        let events = ControlEventsController(stream: { gateway in
            gateways.append(gateway)
            return AsyncThrowingStream { continuations.append($0) }
        })
        let control = VisionControlEnrollmentController(events: events, client: stream,
            now: { Double(memory.now) / 1000 }, schedule: { _, _ in })
        events.setForeground(true); events.setVisible(true)
        stream.connected = true; stream.resumeOwnerEnrollment()
        settle { gateways.count == 1 }
        let request = try gateways[0].request(), refused = stream.ownerEnrollmentCredential!
        let initialRequests = memory.requests.count
        memory.token = String(repeating: "d", count: 64)
        memory.postHandler = { route, _ in
            switch route {
            case .readbackChallenge: return memory.response(401, .object(["error": .string("CREDENTIAL_EXPIRED")]))
            case .challenge: return memory.response(memory.fixture["challengeResponse"]!)
            case .enroll: return memory.response(memory.credential)
            case .readback: fatalError("확정 만료 응답 뒤 readback POST 없음")
            }
        }
        switch mode {
        case "stale-peer": stream.connection = NWConnection()
        case "stale-lease": stream.visionDisplaySelection.lease = .init(window: UUID())
        case "cancel": stream.cancelOwnerEnrollment()
        default: break
        }
        let status = mode == "403" ? 403 : 401
        let reason = mode == "403" ? "DEVICE_REVOKED" : "CREDENTIAL_EXPIRED"
        let refusal = ControlEventsAuthenticationFailure(status: status,
            body: data(.object(["error": .string(reason)])),
            authorization: mode == "wrong-request" ? "Bearer wrong" : request.value(forHTTPHeaderField: "Authorization")!)
        var completed = false
        var replacement: ControlEventsGateway?
        Task { @MainActor in
            replacement = await gateways[0].recoverAuthentication?(refusal, true)
            completed = true
        }
        settle { completed }
        if mode == "401-renew" {
            try check(replacement != nil && stream.ownerEnrollmentCredential != refused && memory.requests.count == initialRequests + 3,
                      "실제 Vision gateway callback → 원 요청 자격 unauthorized → readback 만료 → 1회 trustedRenew")
            try check(try replacement!.request().value(forHTTPHeaderField: "Authorization") == stream.ownerEnrollmentCredential?.authorizationValue,
                      "새 gateway는 확정 새 자격만 사용")
            var staleCompleted = false
            Task { @MainActor in
                let old = await gateways[0].recoverAuthentication?(refusal, true)
                precondition(old == nil); staleCompleted = true
            }
            settle { staleCompleted }
            try check(memory.requests.count == initialRequests + 3, "늦은 옛 401이 현재 새 credential로 바꿔치기되지 않음")
        } else if mode == "403" {
            try check(replacement == nil && stream.ownerEnrollmentCredential == nil && !events.configured,
                      "실제 Vision gateway 403 철회 격리 및 자동 재접속 0")
            stream.cancelOwnerEnrollment(); stream.resumeOwnerEnrollment()
            try check(memory.requests.count == initialRequests && stream.ownerEnrollmentCredential == nil,
                      "403 뒤 소비자 교체에도 새 grant 0")
        } else {
            try check(replacement == nil && memory.requests.count == initialRequests,
                      "실제 gateway 현재성·정확 요청 자격 변경시 unauthorized 부작용 0 \(mode)")
        }
        _ = control
        events.release(); stream.cancelOwnerEnrollment()
    }
    for mode in ["401", "403-revoked", "403-owner-denied", "401-cas-failure", "401-read-failure", "stale-refusal"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        var gateways: [ControlEventsGateway] = []
        var continuations: [AsyncThrowingStream<ControlEventsStreamItem, Error>.Continuation] = []
        let events = ControlEventsController(stream: { gateway in
            gateways.append(gateway)
            return AsyncThrowingStream { continuations.append($0) }
        })
        let control = VisionControlEnrollmentController(events: events, client: stream,
            now: { Double(memory.now) / 1000 }, schedule: { _, _ in })
        events.setForeground(true); events.setVisible(true)
        stream.connected = true; stream.resumeOwnerEnrollment()
        settle { gateways.count == 1 }
        let initial = memory.requests.count
        let original = stream.ownerEnrollmentCredential!
        memory.postHandler = { route, _ in
            switch route {
            case .readbackChallenge: return memory.response(401, .object(["error": .string("CREDENTIAL_EXPIRED")]))
            case .challenge: return memory.response(memory.fixture["challengeResponse"]!)
            case .enroll: return memory.response(memory.credential)
            case .readback: fatalError("확정 만료 뒤 readback POST 없음")
            }
        }
        memory.token = String(repeating: "d", count: 64)
        let first = try gateways[0].request()
        continuations[0].finish(throwing: ControlEventsAuthenticationFailure(status: 401,
            body: data(.object(["error": .string("CREDENTIAL_EXPIRED")])),
            authorization: first.value(forHTTPHeaderField: "Authorization")!))
        settle { gateways.count == 2 }
        try check(memory.requests.count == initial + 3 && memory.requests.suffix(3).map(\.0) == [.readbackChallenge, .challenge, .enroll], "첫 이벤트 401만 readback 만료·challenge·enroll 한 번")
        let renewed = stream.ownerEnrollmentCredential!
        let beforeSecond = memory.requests.count
        memory.token = String(repeating: "e", count: 64)
        let second = try gateways[1].request()
        memory.casFails = mode == "401-cas-failure"
        memory.loadFails = mode == "401-read-failure"
        let status = mode.hasPrefix("403") ? 403 : 401
        let reason = mode == "403-revoked" ? "DEVICE_REVOKED" : mode == "403-owner-denied" ? "OWNER_TRUST_DENIED" : "CREDENTIAL_EXPIRED"
        continuations[1].finish(throwing: ControlEventsAuthenticationFailure(status: status,
            body: data(.object(["error": .string(reason)])),
            authorization: mode == "stale-refusal" ? original.authorizationValue : second.value(forHTTPHeaderField: "Authorization")!))
        settle { !events.configured }
        let extra = memory.requests.count - beforeSecond
        FileHandle.standardOutput.write(Data("실제 두 번 거절 chain \(mode): 최초 HTTP \(initial), 첫 갱신 HTTP \(beforeSecond - initial), 두번째 거절 추가 HTTP \(extra), 구독 \(gateways.count)\n".utf8))
        try check(extra == 0 && gateways.count == 2, "같은 subscription epoch 두번째 401은 새 등록 HTTP·grant 0")
        if mode == "stale-refusal" {
            try check(stream.ownerEnrollmentCredential == renewed, "늦은 옛 401을 현재 credential로 바꿔치기하거나 격리하지 않음")
        } else {
            try check(stream.ownerEnrollmentCredential == nil, "두번째 정확 refused credential 즉시 격리")
            let journal = object(try J.parse(memory.raw!, limit: 1_048_576))
            if mode == "401" {
                try check(journal["rejectedTokenHash"] == .string(renewed.tokenHash), "두번째 거절 hash를 CAS journal에 보존")
            } else if status == 403 {
                try check(journal["terminal"] == .string(reason), "예산 없는 403도 terminal 신뢰 거절 보존")
            }
            memory.casFails = false; memory.loadFails = false
            memory.postHandler = { _, _ in memory.response(503, .object(["error": .string("ENROLLMENT_PROVIDER_UNAVAILABLE")])) }
            stream.cancelOwnerEnrollment(); stream.resumeOwnerEnrollment()
            settle { stream.ownerEnrollment?.phase != .requesting }
            try check(stream.ownerEnrollmentCredential == nil, "소비자 교체·저장소 복구 후 거절 token cache 재수용 0")
        }
        _ = control
        events.release(); stream.cancelOwnerEnrollment()
    }
    print("Vision 창·peer·pin·취소·기기키·profile·로컬 만료 추가 검사 통과. 누적 \(assertions)개.")
}
