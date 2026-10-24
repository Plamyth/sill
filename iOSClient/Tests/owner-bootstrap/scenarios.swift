let fixturePin = Data(repeating: 0x37, count: 32)
let fixtureProfile = OwnerMacBootstrap(macID: MacID.make(fingerprint: fixturePin), fingerprint: Base64URL.encode(fixturePin),
                                       addresses: ["100.64.1.2", "fd7a:115c:a1e0::2"], remotePort: 7455)!
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
try JSONEncoder().encode(fixtureProfile).write(to: fixtureURL)
var count = 0
var retryFailures = 0
var retryCount = 0
func checkRetry(_ value: Bool, _ label: String) {
    retryCount += 1
    if !value { retryFailures += 1; print("FAIL " + label) }
}
func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1 }
func reset() {
    Clock.now = 100; Clock.events = []; Clock.main = []; Clock.network = []; Clock.networkPaused = false
    UserDefaults.standard.values = [:]
    Bundle.resource = fixtureURL; Bundle.reads = 0
    DeviceIdentity.present = true; DeviceIdentity.missing = false; DeviceIdentity.throwsOnCreate = false
    DeviceIdentity.creates = 0; DeviceIdentity.forgets = 0
    RemoteConnector.all = []
}
func client() -> StreamClient {
    let c = StreamClient(); c.startRemote(); c.armSavedMacAutoConnect(); return c
}
func result() -> PairResult {
    PairResult(ok: true, macID: fixtureProfile.macID, name: "검사 Mac", recognitionKey: Base64URL.encode(Data(repeating: 7, count: 32)),
               method: OwnerMacBootstrap.method)
}
func answer(_ socket: NWConnection, _ r: PairResult = result()) {
    let payload = Wire.encode(r)
    let bytes = StreamMessage(kind: .pairResult, timestamp: 0, isKeyframe: false, payload: payload).serialized()
    socket.deliver(Data(bytes.prefix(StreamMessage.headerLength)))
    socket.deliver(payload, ended: true)
}
reset()
do {
    let c = client()
    check("실제 startup에서 최초 빈 저장소만 등록 시작", RemoteConnector.all.count == 1 && c.ownerBootstrap.wasInitiallyEmpty)
    let connector = c.ownerBootstrapDial!
    check("profile 주소와 port만 순서대로 사용", connector.candidates.map(\.host) == fixtureProfile.addresses && connector.candidates.allSatisfy { $0.port == 7455 })
    for _ in 0..<5 { c.discoveryChanged(); c.armSavedMacAutoConnect(); c.startRemote() }
    check("중복 시작·discovery 콜백은 재발행하지 않음", RemoteConnector.all.count == 1)
    let socket = connector.win(); Clock.flush()
    let request = Wire.decode(PairRequest.self, from: Data(socket.sent[0].dropFirst(StreamMessage.headerLength)))!
    check("owner 전용 v2 proof 빈값 name/model", request.v == 2 && request.method == OwnerMacBootstrap.method && request.proof == "" && request.name == "검사 iPad" && request.model == "iPadFixture" && request.cable == nil)
    answer(socket); Clock.flush()
    check("검증 뒤에만 저장하고 정식 dialSaved", c.persists == 1 && c.dials == [fixtureProfile.macID] && socket.cancelled)
    let saved = c.savedMacs[0]
    check("보수적 homeTLS 정책과 profile 주소 보존", saved.homeTLS == true && saved.method == OwnerMacBootstrap.method && saved.addresses.map(\.host) == fixtureProfile.addresses && saved.remotePort == 7455)
    check("선호 ID 저장과 기존 기기키 재사용", UserDefaults.standard.string(forKey: StreamClient.ownerPreferredKey) == saved.macID && DeviceIdentity.creates == 0 && DeviceIdentity.forgets == 0)
    c.remoteDialFailed(macID: saved.macID, why: c.dialReasons.last!, failure: .noAnswer, candidate: nil)
    print("COUNTEREXAMPLE owner-success-dial automatic=\(c.dialReasons.last == .automatic) failures=\(c.reconnect?.remoteFailures ?? -1) retryChecks=\(c.retryChecks)")
    checkRetry(c.dialReasons.last == .automatic, "자동 owner 등록 성공은 수동 afterPairing 연결로 끝내지 않음")
    checkRetry(c.reconnect?.remoteFailures == 1 && (c.reconnect?.nextRemoteAt ?? 0) > Clock.now && c.retryChecks == 1,
               "가짜 자동 등록 뒤 실제 noAnswer 처리도 기존 재시도 의도를 보존")
    c.wentToBackground(); c.cameForward(); Clock.advance(100)
    check("저장 후 활성화는 bootstrap 재발행 안함", RemoteConnector.all.count == 1)
}
for value: Any in ["[]", "corrupt", Data(), 1] {
    reset(); UserDefaults.standard.values[SavedMacs.defaultsKey] = value
    let c = client(); c.discoveryChanged()
    check("빈 배열·손상·비문자열 원시 저장키가 최초 자격을 막음", RemoteConnector.all.isEmpty && Bundle.reads == 0 && !c.ownerBootstrap.wasInitiallyEmpty)
}
for value: Any in ["", "missing", 1] {
    reset(); UserDefaults.standard.values[StreamClient.ownerPreferredKey] = value
    _ = client()
    check("선호키가 값·형식과 무관하게 bootstrap 차단", RemoteConnector.all.isEmpty)
}
for denied in [false, true] {
    reset()
    let c = StreamClient(); c.savedMacs = [SavedMac(macID: fixtureProfile.macID, fingerprint: fixtureProfile.fingerprint,
        name: "이전 Mac", recognitionKey: result().recognitionKey!, remotePort: 7455, addresses: [],
        infoIssuedAt: 0, pairedAt: Date(), method: "code", homeTLS: true, revoked: denied, newKey: denied)]
    let original = SavedMacs.encode(c.savedMacs)
    UserDefaults.standard.set(original, forKey: SavedMacs.defaultsKey)
    DeviceIdentity.present = false; DeviceIdentity.missing = true
    c.startRemote(); c.armSavedMacAutoConnect(); c.wentToBackground(); c.cameForward()
    check("기기 키 누락에도 정상·차단 신뢰 원본을 그대로 보존", SavedMacs.encode(c.savedMacs) == original && UserDefaults.standard.string(forKey: SavedMacs.defaultsKey) == original && c.persists == 0)
    check("기기 키 누락을 최초 등록으로 우회하거나 키를 변경하지 않음", RemoteConnector.all.isEmpty && c.dials.isEmpty && DeviceIdentity.creates == 0 && DeviceIdentity.forgets == 0)
}
reset()
do {
    let c = StreamClient(); c.appInForeground = false; c.startRemote(); c.armSavedMacAutoConnect()
    check("준비 중 background는 미시도 대기", RemoteConnector.all.isEmpty && c.ownerBootstrap.phase == .ready)
    c.cameForward()
    check("실제 foreground 경계에서 준비 재개", RemoteConnector.all.count == 1)
    c.cameForward()
    check("기존 bootstrap과 별도 등록 모듈의 foreground 경계를 유지", c.ownerEnrollmentResumes == 1)
    c.wentToBackground()
    check("background는 별도 등록 모듈도 취소", c.ownerEnrollmentCancels == 1)
}
reset()
do {
    DeviceIdentity.present = false; DeviceIdentity.missing = false
    let c = client()
    check("Keychain 잠금·권한오류에는 키생성 없이 보류", RemoteConnector.all.isEmpty && DeviceIdentity.creates == 0 && c.status.contains("잠금"))
    DeviceIdentity.missing = true
    c.wentToBackground(); c.cameForward()
    check("확정 부재가 된 다음 활성화에만 loadOrCreate", DeviceIdentity.creates == 1 && RemoteConnector.all.count == 1)
}
reset()
do {
    DeviceIdentity.present = false; DeviceIdentity.missing = true; DeviceIdentity.throwsOnCreate = true
    let c = client(); c.discoveryChanged(); c.discoveryChanged()
    check("생성 실패는 재발행·삭제 없이 보류", DeviceIdentity.creates == 1 && DeviceIdentity.forgets == 0 && RemoteConnector.all.isEmpty)
}
for phase in 0..<4 {
    reset()
    let c = client(); let first = c.ownerBootstrapDial!
    let socket = first.win()
    if phase != 0 { Clock.flush() }
    if phase == 2 { answer(socket) } // 성공이 main에 도착하기 직전 취소
    if phase == 3 { c.cancelPairing() } else { c.wentToBackground() }
    Clock.flush(); answer(socket); Clock.flush()
    check("dial winner/교환/저장 직전 취소는 실제 소켓 닫고 late 저장 차단 \(phase)", socket.cancelled && c.savedMacs.isEmpty && c.persists == 0)
    if phase != 3 { c.cameForward() } else { c.wentToBackground(); c.cameForward() }
    check("비활성화만 재시도하고 사용자 취소는 중지 유지 \(phase)", RemoteConnector.all.count == (phase == 3 ? 1 : 2))
    first.onFailed?(0); _ = first.win(); Clock.flush()
    check("이전 세대 callback은 새 시도나 사용자 중지를 대체하지 않음 \(phase)", (phase == 3 ? c.ownerBootstrapDial == nil : c.ownerBootstrapDial === RemoteConnector.all.last) && c.persists == 0)
}
reset()
do {
    let c = client(); let dial = c.ownerBootstrapDial!
    dial.onFailed?(0); Clock.flush(); c.discoveryChanged(); Clock.advance(30)
    check("실패 후 무한 자동 재발행 금지", RemoteConnector.all.count == 1)
    c.wentToBackground(); c.cameForward()
    check("활성화 후 기존 기기키로 제한 재시도", RemoteConnector.all.count == 2 && DeviceIdentity.creates == 0)
}
for tamper in 0..<9 {
    reset()
    let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    var r = result()
    switch tamper {
    case 0: r.ok = false
    case 1: r.method = "cable"
    case 2: r.macID = "0000000000000000"
    case 3: r.proof = ""
    case 4: r.recognitionKey = Base64URL.encode(Data(repeating: 1, count: 31))
    case 5: r.recognitionKey = r.recognitionKey! + "="
    case 6: socket.alpn = "sill-pair/1"
    case 7: socket.pin = Data(repeating: 4, count: 32)
    default: r.method = nil
    }
    answer(socket, r); Clock.flush()
    check("거부·method·ID·proof·recognition·실제 ALPN·peer pin 검증 \(tamper)", c.persists == 0 && socket.cancelled)
}
for malformed in 0..<4 {
    reset(); let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    switch malformed {
    case 0: socket.deliver(Data("garbage".utf8))
    case 1:
        let frame = StreamMessage(kind: .pairRequest, timestamp: 0, isKeyframe: false, payload: Data([1])).serialized()
        socket.deliver(Data(frame.prefix(StreamMessage.headerLength)))
    case 2: Clock.advance(RemoteDialPolicy.pairingReplyDeadline + 1)
    default: socket.stateUpdateHandler?(.failed(1))
    }
    Clock.flush()
    check("형식·종류·timeout·전송오류는 저장 없이 닫음 \(malformed)", c.persists == 0 && socket.cancelled)
}
reset()
do {
    let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    UserDefaults.standard.set("손상된 다른 기록", forKey: SavedMacs.defaultsKey)
    answer(socket); Clock.flush()
    check("교환 중 새 trust raw가 나타나면 저장 안함", c.persists == 0)
}
reset()
do {
    let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    c.dialSaved("수동 연결", why: .tap); answer(socket); Clock.flush()
    check("수동 연결이 진행 교환 소켓을 취소", socket.cancelled && c.persists == 0 && c.dials == ["수동 연결"])
}
for boundary in 0..<7 {
    reset(); let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    c.runBoundary(boundary); answer(socket); Clock.flush()
    check("실제 수동 연결·새 페어링 진입 취소 구간 \(boundary)", socket.cancelled && c.persists == 0)
    c.wentToBackground(); c.cameForward(); c.discoveryChanged()
    check("사용자 선택 뒤 foreground는 등록을 되살리지 않음 \(boundary)", RemoteConnector.all.count == 1 && c.ownerBootstrap.phase == .stopped)
}
reset()
do {
    let c = client(); let socket = c.ownerBootstrapDial!.win(); Clock.flush()
    c.pairTyped(code: "잘못된 코드", address: "bad host", overlay: false)
    answer(socket); Clock.flush()
    check("실제 pairTyped 입력 오류도 이전 등록을 취소", c.pairing == .failed(.address) && socket.cancelled && c.persists == 0)
}
reset()
do {
    let old = client(); old.cancelPairing(); old.wentToBackground(); old.cameForward()
    check("명시취소는 같은 실행에서 중지 유지", RemoteConnector.all.count == 1)
    let relaunched = client()
    check("새 앱 실행은 같은 기존 기기키로 제한 시도", RemoteConnector.all.count == 2 && relaunched.ownerBootstrapDial != nil && DeviceIdentity.creates == 0)
}
for pause in [false, true] {
    reset()
    let c = client()
    let socket = c.ownerBootstrapDial!.win()
    Clock.networkPaused = true
    Clock.flush()
    if pause { c.wentToBackground() } else { c.cancelPairing() }
    Clock.resumeNetwork(); Clock.flush()
    check("전송 큐 대기 중 사용자 취소·OS 중단은 kind19를 보내지 않음 \(pause)", socket.sent.isEmpty && socket.cancelled && c.persists == 0)
}
reset()
do {
    let socket = NWConnection()
    let exchange = OwnerBootstrapExchange(connection: socket, profile: fixtureProfile, name: "검사 iPad", model: "iPadFixture", queue: DispatchQueue())
    Clock.networkPaused = true
    exchange.cancel()
    exchange.start { _ in preconditionFailure("시작 전 취소 후 결과가 전달됨") }
    Clock.resumeNetwork()
    check("시작 전 취소는 kind19 송신과 결과 전달을 막음", socket.sent.isEmpty && socket.cancelled)
}
reset()
do {
    let socket = NWConnection()
    let exchange = OwnerBootstrapExchange(connection: socket, profile: fixtureProfile, name: "검사 iPad", model: "iPadFixture", queue: DispatchQueue())
    var completions = 0
    Clock.networkPaused = true
    exchange.start { _ in completions += 1 }
    exchange.start { _ in preconditionFailure("중복 시작 결과가 전달됨") }
    Clock.resumeNetwork()
    check("정상 교환은 중복 시작에도 kind19를 한 번만 보냄", socket.sent.count == 1 && !socket.cancelled)
    answer(socket)
    check("정상 교환 결과도 한 번만 전달", completions == 1)
}
reset()
do {
    let socket = NWConnection(); socket.sendError = 1
    let exchange = OwnerBootstrapExchange(connection: socket, profile: fixtureProfile, name: "검사 iPad", model: "iPadFixture", queue: DispatchQueue())
    var completions = 0
    exchange.start { value in precondition(value == nil); completions += 1 }
    exchange.cancel()
    check("동기 전송 오류도 잠금 교착 없이 한 번 종료하고 읽기를 시작하지 않음", completions == 1 && socket.cancelled && socket.sent.count == 1 && socket.reads.isEmpty)
}
print("PASS \(count) owner bootstrap startup/exchange checks; deterministic stand-ins, no device/network/Keychain effects")

reset()
do {
    let manual = StreamClient(); manual.pairing = .working
    manual.remoteDialFailed(macID: fixtureProfile.macID, why: .afterPairing, failure: .noAnswer, candidate: nil)
    checkRetry(manual.reconnect == nil && manual.retryChecks == 0 && manual.pairing == .idle,
               "기존 수동 afterPairing 실패에는 자동 재시도를 추가하지 않음")
}
print("OWNER_STARTUP_RETRY total=\(retryCount) failures=\(retryFailures)")
if retryFailures > 0 { exit(1) }
