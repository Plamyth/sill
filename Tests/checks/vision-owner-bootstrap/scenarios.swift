let fixturePin = Data(repeating: 0x37, count: 32)
let profile = OwnerMacBootstrap(macID: MacID.make(fingerprint: fixturePin), fingerprint: Base64URL.encode(fixturePin), addresses: ["100.64.1.2"], remotePort: 7455)!
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
try JSONEncoder().encode(profile).write(to: fixtureURL)
var count = 0
func check(_ message: String, _ value: Bool) { precondition(value, message); count += 1 }
func reset() {
    Clock.now = 100; Clock.main = []; Clock.events = []; Clock.network = []; Clock.networkPaused = false
    UserDefaults.standard.values = [:]; Bundle.resource = fixtureURL; Bundle.reads = 0
    DeviceIdentity.present = true; DeviceIdentity.missing = false; DeviceIdentity.throwsOnCreate = false
    DeviceIdentity.creates = 0; DeviceIdentity.forgets = 0; DeviceIdentity.fingerprint = Data(repeating: 0x41, count: 32)
    RemoteConnector.all = []; VisionReleaseTestContext.isTestBundle = false
}
func client() -> StreamClient { let c = StreamClient(); c.startRemote(); c.startOwnerBootstrap(); return c }
func result() -> PairResult { PairResult(ok: true, macID: profile.macID, name: "검사 Mac", recognitionKey: Base64URL.encode(Data(repeating: 7, count: 32)), method: OwnerMacBootstrap.method) }
func answer(_ socket: NWConnection) {
    let payload = Wire.encode(result())
    let bytes = StreamMessage(kind: .pairResult, timestamp: 0, isKeyframe: false, payload: payload).serialized()
    socket.deliver(Data(bytes.prefix(StreamMessage.headerLength))); socket.deliver(payload, ended: true)
}
reset()
do {
    let c = client(); check("최초 실행에서 공개 설정 주소만 선택", RemoteConnector.all.count == 1 && c.ownerBootstrap.wasInitiallyEmpty && c.ownerBootstrapDial!.candidates.map(\.host) == profile.addresses)
    let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    check("한 번만 등록 요청", socket.sent.count == 1)
    let request = Wire.decode(PairRequest.self, from: Data(socket.sent[0].dropFirst(StreamMessage.headerLength)))!
    check("소유자 전용 요청 계약", request.v == 2 && request.method == OwnerMacBootstrap.method && request.proof == "" && request.cable == nil)
    answer(socket); Clock.flush()
    check("승인 뒤 저장·정식 연결", c.persists == 1 && c.dials == [profile.macID] && socket.cancelled)
    check("주소·TLS pin·기존 키 보존", c.savedMacs[0].fingerprint == profile.fingerprint && c.savedMacs[0].addresses.map(\.host) == profile.addresses && DeviceIdentity.creates == 0 && DeviceIdentity.forgets == 0)
}
for key in [SavedMacs.defaultsKey, StreamClient.ownerPreferredKey] {
    for value: Any in ["[]", "손상", Data(), 1] {
        reset(); UserDefaults.standard.values[key] = value
        let c = client(); c.resumeOwnerBootstrapAfterForeground()
        check("기존 원시 키는 최초 등록으로 우회하지 않음", RemoteConnector.all.isEmpty && Bundle.reads == 0)
    }
}
for knownMissing in [true, false] {
    reset()
    let c = StreamClient()
    c.savedMacs = [SavedMac(macID: profile.macID, fingerprint: profile.fingerprint, name: "기존 Mac", recognitionKey: result().recognitionKey!, remotePort: 7455, addresses: [], infoIssuedAt: 37, pairedAt: Date(timeIntervalSince1970: 41), method: "code", homeTLS: true)]
    c.savedMacs[0].lastWorked = "100.64.1.2|7455"
    c.savedMacs[0].lastConnectedAt = Date(timeIntervalSince1970: 53)
    c.savedMacs[0].revoked = false
    c.savedMacs[0].newKey = false
    let before = c.savedMacs
    let raw = "  " + SavedMacs.encode(before) + "\n"
    UserDefaults.standard.set(raw, forKey: SavedMacs.defaultsKey)
    UserDefaults.standard.set(profile.macID, forKey: StreamClient.ownerPreferredKey)
    DeviceIdentity.present = false; DeviceIdentity.missing = knownMissing
    c.startRemote(); c.startOwnerBootstrap(); c.resumeOwnerBootstrapAfterForeground()
    Clock.advance(60)
    check("키 누락·일시 잠금에서 신뢰와 메타데이터 보존 \(knownMissing)", c.savedMacs == before && c.persists == 0)
    check("원시 저장 문자열과 선호 Mac 보존 \(knownMissing)", UserDefaults.standard.string(forKey: SavedMacs.defaultsKey) == raw && UserDefaults.standard.string(forKey: StreamClient.ownerPreferredKey) == profile.macID)
    check("새 키·등록·연결 없이 최초 자격 유지 \(knownMissing)", RemoteConnector.all.isEmpty && DeviceIdentity.creates == 0 && DeviceIdentity.forgets == 0 && c.dials.isEmpty && !c.ownerBootstrap.wasInitiallyEmpty && Bundle.reads == 0)
}
for invalid in ["background", "scene", "retired", "lease", "test", "cable"] {
    reset(); let c = StreamClient()
    switch invalid {
    case "background": c.appInForeground = false
    case "scene": c.visionStartupForeground = false
    case "retired": c.visionWindowRetired = true
    case "lease": c.visionDisplaySelection.lease = nil
    case "test": VisionReleaseTestContext.isTestBundle = true
    default: c.visionCableBootstrap.launch = .cable
    }
    c.armOwnerBootstrap(); c.startOwnerBootstrap()
    check("권한 없는 창·시험·유선 경로는 전송 안함 \(invalid)", RemoteConnector.all.isEmpty)
}
for stage in 0...2 {
    for change in ["lease", "key", "defaults", "scene", "retired", "session"] {
        reset(); let c = client(); let connector = c.ownerBootstrapDial!; let socket = connector.win()
        if stage > 0 { Clock.flush() }
        if stage == 2 { answer(socket) }
        switch change {
        case "lease": c.visionDisplaySelection.lease = VisionWindowLease(window: UUID())
        case "key": DeviceIdentity.fingerprint = Data(repeating: 0x42, count: 32)
        case "defaults": UserDefaults.standard.values[SavedMacs.defaultsKey] = "[]"
        case "scene": c.visionStartupForeground = false
        case "retired": c.visionWindowRetired = true
        default: c.connection = NWConnection()
        }
        Clock.flush(); answer(socket); Clock.flush()
        check("늦은 응답에서 창·키·저장·활성 상태를 재확인 \(stage)/\(change)", c.persists == 0 && c.dials.isEmpty && socket.cancelled)
    }
}
for manual in [false, true] {
    reset(); let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    c.cancelOwnerBootstrap(resumable: !manual); Clock.flush(); answer(socket); Clock.flush()
    check("취소 뒤 저장 차단", c.persists == 0 && socket.cancelled)
    c.resumeOwnerBootstrapAfterForeground()
    check("OS 비활성화만 새 활성화에서 재시도", RemoteConnector.all.count == (manual ? 1 : 2))
}
reset()
do {
    DeviceIdentity.present = false; DeviceIdentity.missing = false
    let c = client(); check("키 잠금은 새 키를 만들지 않음", DeviceIdentity.creates == 0 && RemoteConnector.all.isEmpty)
    DeviceIdentity.missing = true; c.resumeOwnerBootstrapAfterForeground()
    check("확정 부재일 때만 키 생성", DeviceIdentity.creates == 1 && RemoteConnector.all.count == 1)
}
reset()
do {
    let socket = NWConnection(); Clock.networkPaused = true
    let exchange = OwnerBootstrapExchange(connection: socket, profile: profile, name: "검사", model: "Vision", queue: DispatchQueue())
    exchange.start { _ in }; exchange.cancel(); Clock.resumeNetwork()
    check("큐 정지 중 취소도 실제 등록 송신 차단", socket.sent.isEmpty && socket.cancelled)
}
reset()
do {
    let socket = NWConnection(); let exchange = OwnerBootstrapExchange(connection: socket, profile: profile, name: "검사", model: "Vision", queue: DispatchQueue())
    exchange.start { _ in }; exchange.start { _ in }
    check("중복 start는 한 번만 송신", socket.sent.count == 1)
    Clock.advance(9); check("등록 응답 기한 만료시 소켓 종료", socket.cancelled)
}
print("Vision owner bootstrap \(count)개 통과. 실제 Vision 어댑터·공통 교환, I/O 대역 검사. 실기기·호스트 연결 없음.")
