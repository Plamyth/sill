import Foundation
import StreamProtocol

@MainActor
func moveChecks() throws {
    func client(_ memory: Memory) -> StreamClient {
        runtimeMemory = memory
        Bundle.url = URL(fileURLWithPath: CommandLine.arguments[2])
        DeviceIdentity.value = .init(privateKey: .init(Data(memory.binding.deviceSPKI.suffix(65))), fingerprint: memory.binding.deviceFingerprint)
        let stream = StreamClient()
        let peer = NWConnection(); peer.pin = memory.binding.hostPin
        stream.connection = peer; stream.session = .init(macID: memory.binding.macID)
        stream.savedMacs = [.init(macID: memory.binding.macID, fingerprintData: memory.binding.hostPin, homeTLS: true)]
        return stream
    }
    for mode in ["handOver", "toWifi-adopt", "rescue-adopt", "fromDirect", "fromRemote"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        var gateways: [ControlEventsGateway] = []
        var subscriptions: [AsyncThrowingStream<ControlEventsStreamItem, Error>.Continuation] = []
        let events = ControlEventsController(stream: { gateway in
            gateways.append(gateway)
            return AsyncThrowingStream { subscriptions.append($0) }
        })
        let manager = VisionControlEnrollmentController(events: events, client: stream,
            now: { Double(memory.now) / 1000 }, schedule: { _, _ in })
        events.setForeground(true); events.setVisible(true)
        stream.connected = true; stream.resumeOwnerEnrollment()
        settle { gateways.count == 1 }
        let a = stream.connection!, oldEnrollment = stream.ownerEnrollment!
        let grant = stream.ownerEnrollmentCredential!, requests = memory.requests.count, writes = memory.writes
        let raw = memory.raw, setterCalls = stream.connectionSetterCalls
        let b = NWConnection(); b.pin = memory.binding.hostPin
        stream.moving = .init(connection: b)
        stream.connectedDirectly = mode == "fromDirect"
        stream.sessionDead = mode == "rescue-adopt"
        stream.session?.route.isRemote = mode == "fromRemote"
        let kind: StreamClient.MoveKind = mode == "toWifi-adopt" ? .toWifi : mode == "fromDirect" ? .fromDirect : mode == "fromRemote" ? .fromRemote : .toCable
        let fenced = mode != "toWifi-adopt" && mode != "rescue-adopt"
        let held = Data([0x7e])
        if !fenced { stream.link.hold(a); stream.link.send(held) }
        stream.finishMove(b, kind: kind, kept: [])
        try check(stream.connection === a && stream.ownerEnrollment === oldEnrollment && events.configured,
                  "실제 finishMove는 기존 입력 drain 전에 등록 소유권을 바꾸지 않음")
        try check(stream.visionInputSession?.moves == [true] && stream.visionInputSession?.releases == 1,
                  "기존 입력 해제·moving admission 보존")
        stream.inputDrain?(); stream.inputDrain = nil
        FileHandle.standardOutput.write(Data("실제 finishMove \(mode): peerB=\(stream.connection === b), setterCalls=\(stream.connectionSetterCalls - setterCalls), oldEnrollment=\(stream.ownerEnrollment === oldEnrollment), menusB=\(stream.menuPeers == [ObjectIdentifier(b)])\n".utf8))
        try check(stream.connection === b && stream.connectionSetterCalls == setterCalls, "실제 SessionLink handOver/adopt는 computed setter를 우회")
        try check(stream.ownerEnrollment !== oldEnrollment && stream.ownerEnrollmentPeer == ObjectIdentifier(b),
                  "실제 우회 이동은 A 등록을 취소하고 현재 B 등록 소비자로 재개")
        settle { gateways.count == 2 }
        try check(stream.ownerEnrollmentCredential == grant && memory.requests.count == requests && memory.writes == writes && memory.raw == raw,
                  "B events는 유효한 저장 자격 재사용, 새 challenge·grant·저장 0")
        try check(try gateways[1].request().value(forHTTPHeaderField: "Authorization") == grant.authorizationValue,
                  "현재 B TLS·lease에서만 event GET 자격 사용")
        reject("옛 A gateway는 B 전환 뒤 자격 사용 불가") { _ = try gateways[0].request() }
        let id = events.reducer.subscription
        if case .terminated = subscriptions[0].yield(.opened(Date())) {} else { fatalError("A 이벤트 구독 취소 누락") }
        try check(events.reducer.subscription == id, "옛 A 이벤트 콜백은 B subscription 변경 0")
        var lateDone = false
        Task { @MainActor in
            let replacement = await gateways[0].recoverAuthentication?(.init(status: 401,
                body: data(.object(["error": .string("CREDENTIAL_EXPIRED")])), authorization: grant.authorizationValue), true)
            precondition(replacement == nil); lateDone = true
        }
        settle { lateDone }
        try check(memory.requests.count == requests && memory.writes == writes && stream.ownerEnrollmentCredential == grant,
                  "옛 A 401은 B에서 HTTP·거절·저장·신규 grant 효과 0")
        try check(stream.menuPeers == [ObjectIdentifier(b)] && stream.settings.resets == 1 && stream.peerResets == 1 && stream.visionInputSession?.moves == [true, false],
                  "실제 이동의 menu·settings·peer media reset·입력 drain 순서 보존")
        if fenced {
            try check(stream.link.reads(a) && stream.link.reads(b) && b.sent.isEmpty && a.sent.count == 1,
                      "실제 handOver의 기존 fence가 viewport를 계속 보류")
            let released = stream.link.release(a)!
            try check(released.held == 1 && b.sent == [stream.viewportBytes] && !stream.link.reads(a), "실제 fence 해제 후에만 B viewport 전송")
        } else {
            try check(b.sent == [held, stream.viewportBytes] && !stream.link.reads(a), "실제 adopt는 held 메시지와 viewport 순서 보존")
            if case .cancelled = a.state {} else { fatalError("사라진 A 연결 취소 누락") }
        }
        _ = manager
        events.release(); stream.cancelOwnerEnrollment()
    }
    for mode in ["pending", "wrong-pin", "drain-cancel"] {
        let memory = try Memory(readbackGolden); memory.holdChallenge = mode == "pending"
        let stream = client(memory)
        let events = ControlEventsController(stream: { _ in fatalError("숨긴 화면 실제 네트워크 금지") })
        let manager = VisionControlEnrollmentController(events: events, client: stream,
            now: { Double(memory.now) / 1000 }, schedule: { _, _ in })
        stream.connected = true; stream.resumeOwnerEnrollment()
        if mode != "pending" { settle { stream.ownerEnrollmentCredential != nil } }
        let a = stream.connection!, parkedA = memory.parked
        let old = stream.ownerEnrollment!, requests = memory.requests.count
        let b = NWConnection(); b.pin = mode == "wrong-pin" ? Data(repeating: 9, count: 32) : memory.binding.hostPin
        stream.moving = .init(connection: b)
        stream.finishMove(b, kind: .toCable, kept: [])
        if mode == "drain-cancel" { stream.moving = nil }
        memory.holdChallenge = false
        stream.inputDrain?(); stream.inputDrain = nil
        if mode == "drain-cancel" {
            try check(stream.connection === a && stream.ownerEnrollment === old && stream.peerResets == 0,
                      "이동이 drain 중 취소되면 기존 A 등록·media·fence 유지")
        } else if mode == "wrong-pin" {
            try check(stream.connection === b && stream.ownerEnrollment == nil && !events.configured && memory.requests.count == requests,
                      "실제 adopt 이후 B pin 불일치는 자동 grant·events 없이 거절")
        } else {
            settle { stream.ownerEnrollmentCredential != nil }
            let raw = memory.raw, writes = memory.writes
            parkedA?(memory.response(memory.fixture["challengeResponse"]!))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try check(memory.requests.map(\.0) == [.challenge, .challenge, .enroll] && memory.receiptCalls == 1,
                      "A 진행 중 challenge 취소 후 B만 한 번 receipt·enroll 수행")
            try check(memory.raw == raw && memory.writes == writes && stream.ownerEnrollmentPeer == ObjectIdentifier(b),
                      "늦은 A 등록 콜백은 B 자격 저장·새 grant 효과 0")
        }
        _ = manager
        events.release(); stream.cancelOwnerEnrollment()
    }
    print("실제 SessionLink·finishMove peer 이동 검사 통과. 누적 \(assertions)개.")
}
