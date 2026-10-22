
var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

Clock.reset()
do {
    let c = StreamClient()
    c.armSavedMacAutoConnect()
    check(c.remoteDials.isEmpty, "discovery grace permits an attached cable to appear")
    Clock.advance(3)
    check(c.remoteDials == ["trusted"], "no Bonjour row connects through saved remote addresses")
    for _ in 0..<3 { c.evaluate() }
    check(c.remoteDials.count == 1, "repeated discovery cannot duplicate the startup remote dial")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac()]
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials == ["trusted"], "Wi-Fi listing does not block the default remote dial")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect()
    check(c.homeDials.count == 1 && c.homeDials[0].0 == .cable && c.remoteDials.isEmpty, "attached cable wins before remote")
    check(c.homeDials.first?.1 == .saved(pin: Data([1, 2, 3])), "cable dial retains the saved TLS pin")
    let cable = c.connection!
    c.cableUnavailable(cable)
    check(c.remoteDials == ["trusted"] && c.homeDials.count == 1, "failed cable falls back to remote instead of Bonjour")
    c.cableUnavailable(cable)
    check(c.remoteDials.count == 1, "stale cable callback cannot duplicate fallback")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!; cable.state = .ready
    c.cableUnavailable(cable)
    check(c.remoteDials == ["trusted"], "TLS-ready cable without first window list still falls back")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!; c.connected = true
    c.cableUnavailable(cable); Clock.advance(3)
    check(c.remoteDials.isEmpty && c.connection === cable, "admitted cable session survives its stale timeout")
}
Clock.reset()
do {
    let c = StreamClient(); c.localNetworkDenied = true
    c.armSavedMacAutoConnect()
    check(c.remoteDials == ["trusted"], "denied local discovery goes directly to remote")
}
Clock.reset()
do {
    let c = StreamClient(); c.armSavedMacAutoConnect(); c.stop(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials.isEmpty, "manual stop cancels delayed automatic intent")
}
Clock.reset()
do {
    DeviceIdentity.available = false
    let c = StreamClient(); c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials.isEmpty, "missing device identity starts no connection")
}
Clock.reset()
do {
    let c = StreamClient(); c.savedMacs[0].eligible = false
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials.isEmpty, "ineligible trust record starts no connection")
}
Clock.reset()
do {
    UserDefaults.standard.values["Sill.preferredTrustedMacID"] = "missing"
    let c = StreamClient(); c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials.isEmpty, "missing preferred identity never selects another Mac")
}
Clock.reset()
do {
    let c = StreamClient(); c.appInForeground = false
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.remoteDials.isEmpty, "background cannot start automatic remote work")
    c.appInForeground = true; c.evaluate()
    check(c.remoteDials == ["trusted"], "foreground resumes waiting startup intent once")
}
Clock.reset()
do {
    let c = StreamClient(); c.armSavedMacAutoConnect()
    Clock.advance(1); c.macs = [FoundMac(cable: true)]; c.evaluate(); Clock.advance(3)
    check(c.homeDials.count == 1 && c.remoteDials.isEmpty, "cable discovered during grace beats the pending remote attempt")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(), FoundMac(cable: true)]
    c.armSavedMacAutoConnect()
    check(c.homeDials.first?.0 == .cable, "Wi-Fi row before cable row cannot mask the cable")
}
for row in [FoundMac(macID: "other", cable: true), FoundMac(carriesTag: false, cable: true),
            FoundMac(cable: true, decision: .plain), FoundMac(cable: true, decision: .waitForTap)] {
    Clock.reset()
    let c = StreamClient(); c.macs = [row]
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials == ["trusted"], "untrusted, untagged, or non-pinned cable cannot replace saved remote target")
}
for busy in 0..<5 {
    Clock.reset()
    let c = StreamClient()
    switch busy {
    case 0: c.remoteDial = 1
    case 1: c.pairing = .working
    case 2: c.pairingDial = 1
    case 3: c.homeAsk = 1
    default: c.pendingLink = 1
    }
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials.isEmpty, "existing remote or pairing activity retains ownership")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); c.closedBeforeAdmission()
    check(c.remoteDials == ["trusted"], "cable closed before its first list falls back once")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); c.securityHandled = true; c.closedBeforeAdmission()
    check(c.remoteDials.isEmpty, "existing home security decision precedes remote fallback")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); c.goodbye = StreamClient.Goodbye(reason: "quit"); c.closedBeforeAdmission()
    check(c.remoteDials.isEmpty, "host goodbye remains under existing goodbye policy")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!; c.savedMacs[0].eligible = false
    c.cableUnavailable(cable)
    check(c.remoteDials.isEmpty && cable.state == .cancelled, "trust invalidated during cable attempt prevents fallback")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!; c.appInForeground = false
    c.cableUnavailable(cable); Clock.advance(3)
    check(c.remoteDials.isEmpty && c.connection == nil, "cable failure in background defers remote work")
    c.appInForeground = true; c.evaluate(); c.evaluate()
    check(c.remoteDials.count == 1, "foreground consumes deferred fallback once")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!; let manual = NWConnection(); c.connection = manual
    c.cableUnavailable(cable)
    check(c.remoteDials.isEmpty && c.connection === manual, "stale cable timeout cannot replace a newer connection")
}
Clock.reset()
do {
    let c = StreamClient(); c.savedMacs[0].method = "owner-tailnet-v1"; c.macs = [FoundMac(cable:true)]
    c.armSavedMacAutoConnect(); Clock.advance(3)
    check(c.homeDials.isEmpty && c.remoteDials == ["trusted"], "owner 시작은 보이는 케이블에 관계없이 저장 Tailnet 경로")
    check(c.startupAttempted, "owner 원격 시작을 wired 진행 상태로 남기지 않음")
    c.evaluate(); Clock.advance(3)
    check(c.remoteDials.count == 1, "owner 시작의 지연 콜백도 중복 연결하지 않음")
}
for cable in [false, true] {
    Clock.reset()
    let c = StreamClient()
    if cable { c.macs = [FoundMac(cable: true)] }
    c.armSavedMacAutoConnect()
    if cable { c.cableUnavailable(c.connection!); c.macs = [] } else { Clock.advance(3) }
    c.failRemote(.noAnswer)
    check(c.reconnect?.remoteFailures == 1, "최초 원격 실패도 기존 재시도 상태에 기록 cable=\(cable)")
    Clock.advance(10)
    check(c.remoteDials.count == 2, "일시적 noAnswer 뒤 버튼 없이 재연결 cable=\(cable) actual=\(c.remoteDials.count)")
    c.failRemote(.vpnOff)
    Clock.advance(10)
    check(c.remoteDials.count == 3, "VPN 일시 불가 뒤 동일 저장 Mac 재시도 cable=\(cable) actual=\(c.remoteDials.count)")
    c.failRemote(.noAnswer)
    Clock.advance(120)
    let count = c.remoteDials.count
    c.evaluate(); _ = c.reconnectIfListed(); Clock.advance(1000)
    check(c.remoteDials.count == count && c.reconnectCheck == nil, "기존 재시도 예산 만료 뒤 새 반복 없음")
}
for failure in [RemoteDialPolicy.Failure.revoked, .wrongMac, .remoteOff] {
    Clock.reset()
    let c = StreamClient(); c.savedMacs[0].method = "owner-tailnet-v1"
    c.armSavedMacAutoConnect(); Clock.advance(3); c.failRemote(failure); Clock.advance(20)
    check(c.remoteDials.count == 1, "명시적 원격 거절 뒤 자동 재시도 없음")
}
Clock.reset()
do {
    let c = StreamClient(); c.armSavedMacAutoConnect(); Clock.advance(3); c.failRemote(.noAnswer)
    c.stop(); Clock.advance(30)
    check(c.remoteDials.count == 1 && c.reconnect == nil, "명시적 중지는 예약된 재시도도 취소")
}
Clock.reset()
do {
    let c = StreamClient(); c.armSavedMacAutoConnect(); Clock.advance(3); c.failRemote(.noAnswer)
    DeviceIdentity.available = false
    Clock.advance(10)
    check(c.remoteDials.count == 1, "재시도 전에 기기 키가 사라지면 소켓을 시작하지 않음")
}
Clock.reset()
do {
    let c = StreamClient(); c.armSavedMacAutoConnect(); Clock.advance(3); c.failRemote(.noAnswer)
    c.connect(to: FoundMac(macID: "other", cable: true)); Clock.advance(30)
    check(c.remoteDials.count == 1 && c.reconnect == nil, "다른 Mac으로 이동하면 이전 자동 재시도는 끝남")
}
Clock.reset()
do {
    let c = StreamClient(); c.macs = [FoundMac(cable: true)]
    c.armSavedMacAutoConnect(); let cable = c.connection!
    DeviceIdentity.available = false
    c.cableUnavailable(cable)
    check(c.remoteDials.isEmpty && c.reconnect == nil, "케이블 실패 전에 기기 키가 사라지면 재시도 권한도 만들지 않음")
}
print("\(checks - failures)/\(checks) checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
