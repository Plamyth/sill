var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) { checks += 1; if !value { failures += 1; print("FAIL \(name)") } }
let pin = Data(repeating: 0x37, count: 32)
func record(_ method: String) -> SavedMac {
    SavedMac(macID: MacID.make(fingerprint: pin), fingerprint: Base64URL.encode(pin), name: "검사 Mac", recognitionKey: Base64URL.encode(Data(repeating: 7, count: 32)), remotePort: 7455,
        addresses: [MacAddress(host:"192.168.1.8",kind:MacAddress.lan,via:"Wi-Fi"),MacAddress(host:"100.64.1.2",kind:MacAddress.vpn,via:"Tailscale"),MacAddress(host:"fd7a:115c:a1e0::2",kind:MacAddress.vpn,via:"Tailscale"),MacAddress(host:"example.ts.net",kind:MacAddress.vpn,via:"Tailscale"),MacAddress(host:"203.0.113.7",kind:MacAddress.internet,via:"")],
        typedAddresses:[MacAddress(host:"127.0.0.1",kind:MacAddress.vpn,via:""),MacAddress(host:"192.168.1.9",kind:MacAddress.vpn,via:"")],infoIssuedAt:0,lastWorked:"192.168.1.8|7455",pairedAt:Date(timeIntervalSince1970:1),method:method,homeTLS:true)
}
let owner = record(OwnerMacBootstrap.method)
let row = FoundMac(id:"row",name:"검사 Mac",door:.plain)
let ownerCandidates = StreamClient.candidates(owner)
check("owner는 숫자 Tailnet 후보만 사용", ownerCandidates.map(\.host) == ["100.64.1.2","fd7a:115c:a1e0::2"])
check("오래된 LAN lastWorked가 VPN보다 먼저 오지 않음", ownerCandidates.first?.host == "100.64.1.2")
check("원본 저장 주소와 typed 주소를 삭제하지 않음", owner.allAddresses.count == 7)
check("저장 기록이 없으면 owner 범위를 적용하지 않음", !RemoteDialPolicy.ownerTailnetScope(nil))
do {
    var mac = owner
    mac.addresses = []
    mac.typedAddresses = [MacAddress(host:"192.168.1.9",kind:MacAddress.vpn,via:"Tailscale")]
    check("숫자 Tailnet 주소가 없으면 LAN 대체 후보를 만들지 않음", StreamClient.candidates(mac).isEmpty)
    mac.typedAddresses = [MacAddress(host:"100.64.1.3",port:7460,kind:MacAddress.lan,via:"")]
    check("typed Tailnet의 포트와 주소를 재사용", StreamClient.candidates(mac).map(\.key) == ["100.64.1.3|7460"])
    mac = owner
    mac.lastWorked = "fd7a:115c:a1e0::2|7455"
    check("허용된 Tailnet lastWorked 우선순위 유지", StreamClient.candidates(mac).first?.host == "fd7a:115c:a1e0::2")
}
for method in ["qr","code","cable","icloud"] {
    let legacy=record(method);let expected=RemoteDialPolicy.order(legacy.allAddresses,remotePort:legacy.remotePort,lastWorked:legacy.lastWorked,localIPv4:StreamClient.localIPv4Networks())
    check("기존 \(method) 후보 순서 보존", StreamClient.candidates(legacy) == expected)
}
do {
    let c=StreamClient();c.records=[owner]
    check("owner Bonjour는 LAN 도어 상태로 막지 않고 저장 VPN 경로로 전달", c.homeDecision(row,macID:owner.macID,tap:false) == .pinned)
    check("재연결 상태 없는 owner row는 최초 연결 허용", c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true))
    check("owner row는 home socket 대신 저장 VPN dial", c.rowConnections == 0 && c.remoteRequests.count == 1 && c.remoteRequests.first?.0 == owner.macID)
    check("재연결 상태 없는 owner row 시작은 실패 표시 가능한 최초 연결", c.remoteRequests.first?.1 == .tap)
    c.status = "연결 중"
    if let reason = c.remoteRequests.first?.1 {
        c.remoteDialFailed(macID:owner.macID,why:reason,failure:.noAnswer,candidate:ownerCandidates.first)
    }
    check("owner 최초 연결 실패를 연결 중 문구로 방치하지 않음", c.status.contains("응답이 없습니다") && c.discoveryChanges == 1)
    c.reconnect = StreamClient.Retry(macID:owner.macID)
    _=c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true)
    check("기존 owner 재연결은 automatic 이유 유지", c.remoteRequests.last?.1 == .automatic)
    if let reason = c.remoteRequests.last?.1 {
        c.remoteDialFailed(macID:owner.macID,why:reason,failure:.noAnswer,candidate:ownerCandidates.first)
    }
    check("owner 재연결의 일시 실패는 기존 지연 재시도 유지", c.reconnect?.remoteFailures == 1 && (c.reconnect?.nextRemoteAt ?? 0) > ProcessInfo.processInfo.systemUptime && c.retryChecks == 1)
    c.remoteDialFailed(macID:owner.macID,why:.automatic,failure:.remoteOff,candidate:nil)
    check("owner 원격 끔 거절은 재시도를 끄고 이유 표시", c.reconnect?.remoteAllowed == false && c.status.contains("원격 접근을 껐습니다"))
    let requestsBeforeTap = c.remoteRequests.count
    var missing = row; missing.endpoint = nil; missing.wired = true
    check("owner는 Bonjour endpoint 없이도 저장 경로 선택", c.dialRow(missing,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true,tap:true))
    check("owner 원격 끔 뒤 명시 탭은 케이블 대신 저장 경로", c.rowConnections == 0 && c.remoteRequests.count == requestsBeforeTap + 1 && c.remoteRequests.last?.1 == .tap)
    c.session=Session(macID:owner.macID);c.moveHomeIfListed()
    check("owner 자동 home 이동은 준비 단계에서 중지", c.homeEligible == 0)
    for kind in MoveKind.allCases { c.startMove(to:7,kind:kind,fallback:9) }
    check("owner home 이동 socket 생성 직전도 차단", c.moveCreated == 0)
}
for failure: RemoteDialPolicy.Failure in [.revoked,.wrongMac,.remoteOff] {
    let c = StreamClient(); c.records = [owner]; c.reconnect = StreamClient.Retry(macID:owner.macID)
    check("owner \(failure) 실패 전 자동 원격 요청 시작", c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true) && c.remoteRequests.count == 1 && c.remoteRequests.last?.1 == .automatic)
    c.remoteDialFailed(macID:owner.macID,why:.automatic,failure:failure,candidate:ownerCandidates.first)
    check("owner \(failure) 실제 실패 콜백이 자동 원격 재시도 중지", c.reconnect?.remoteAllowed == false)
    let requestsBeforeRow = c.remoteRequests.count
    let dialed = c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true)
    check("owner \(failure) 실패 뒤 자동 Bonjour row 차단", !dialed)
    check("owner \(failure) 실패 뒤 원격 요청 미증가 \(requestsBeforeRow)→\(c.remoteRequests.count)", c.remoteRequests.count == requestsBeforeRow && c.rowConnections == 0)
}
do {
    let c = StreamClient(); c.records = [owner]
    c.reconnect = StreamClient.Retry(macID:"other-mac",remoteAllowed:false)
    check("다른 Mac의 중지 기록은 owner row 연결을 막지 않음", c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true))
    check("다른 Mac의 중지 기록이 있으면 owner 최초 연결 이유 유지", c.remoteRequests.count == 1 && c.remoteRequests.last?.1 == .tap && c.rowConnections == 0)
}
for method in ["qr","code","cable","icloud"] {
    let legacy=record(method);let c=StreamClient();c.records=[legacy]
    c.reconnect = StreamClient.Retry(macID:legacy.macID,remoteAllowed:false)
    check("기존 \(method) plain 도어의 업그레이드 요구 보존", c.homeDecision(row,macID:legacy.macID,tap:false) == .updateSill)
    _=c.dialRow(row,macID:legacy.macID,trust:.saved(pin:pin),tagNamed:true)
    check("기존 \(method) row 경로 보존", c.rowConnections == 1 && c.remoteRequests.isEmpty)
    var wired = row; wired.wired = true
    _=c.dialRow(wired,macID:legacy.macID,trust:.saved(pin:pin),tagNamed:true,tap:true)
    check("기존 \(method) 수동 유선 연결 우선순위 유지", c.endpoints.last == 9 && c.remoteRequests.isEmpty)
    var missing = row; missing.endpoint = nil
    check("기존 \(method) endpoint 없는 row는 연결하지 않음", !c.dialRow(missing,macID:legacy.macID,trust:.saved(pin:pin),tagNamed:true))
    c.dialSaved(legacy.macID,why:.connectRemotely)
    check("기존 \(method) 수동 원격 연결 유지", c.remoteRequests.count == 1)
    c.session=Session(macID:legacy.macID);c.moveHomeIfListed();c.startMove(to:7,kind:.fromRemote,fallback:nil)
    check("기존 \(method) home 이동 경로 보존", c.homeEligible == 1 && c.moveCreated == 1)
}
for flag in ["revoked","newKey"] {
    var invalid=owner
    if flag == "revoked" { invalid.revoked=true } else { invalid.newKey=true }
    let c=StreamClient();c.records=[invalid]
    check("owner \(flag) 기록을 자동 home 신뢰로 승격하지 않음", c.homeDecision(row,macID:invalid.macID,tap:false) != .pinned)
    _=c.dialRow(row,macID:invalid.macID,trust:.saved(pin:pin),tagNamed:true)
    check("owner \(flag) 직접 row 호출도 새 연결을 만들지 않음", c.rowConnections == 0 && c.remoteRequests.isEmpty)
    for reason: StreamClient.DialReason in [.tap,.automatic,.connectRemotely] { c.dialSaved(invalid.macID,why:reason) }
    check("owner \(flag) 저장 연결 진입도 차단", c.remoteRequests.isEmpty && !c.status.isEmpty)
    var legacy = invalid; legacy.method = "qr"; c.records = [legacy]
    c.dialSaved(legacy.macID,why:.connectRemotely)
    check("기존 qr \(flag) 수동 원격 연결 계약 유지", c.remoteRequests.count == 1)
}
do {
    var invalid = owner; invalid.fingerprint = "invalid"
    let c = StreamClient(); c.records = [invalid]
    check("owner 손상된 pin은 row 연결 거부", !c.dialRow(row,macID:invalid.macID,trust:.saved(pin:pin),tagNamed:true))
    c.dialSaved(invalid.macID,why:.tap)
    check("owner 손상된 pin은 저장 연결 거부", c.remoteRequests.isEmpty && c.rowConnections == 0)
    c.records = []
    c.dialSaved(owner.macID,why:.tap)
    check("사라진 저장 기록으로 원격 연결하지 않음", c.remoteRequests.isEmpty)
}
print("Owner session routing \(checks)개, 실패 \(failures)개. 실제 후보/진입 메서드와 I/O 대역 검사.")
if failures != 0 { exit(1) }
