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
for method in ["qr","code","cable","icloud"] {
    let legacy=record(method);let expected=RemoteDialPolicy.order(legacy.allAddresses,remotePort:legacy.remotePort,lastWorked:legacy.lastWorked,localIPv4:StreamClient.localIPv4Networks())
    check("기존 \(method) 후보 순서 보존", StreamClient.candidates(legacy) == expected)
}
do {
    let c=StreamClient();c.records=[owner]
    check("owner Bonjour는 LAN 도어 상태로 막지 않고 저장 VPN 경로로 전달", c.homeDecision(row,macID:owner.macID,tap:false) == .pinned)
    _=c.dialRow(row,macID:owner.macID,trust:.saved(pin:pin),tagNamed:true)
    check("owner row는 home socket 대신 저장 VPN dial", c.rowConnections == 0 && c.remoteRequests.count == 1 && c.remoteRequests.first?.0 == owner.macID)
    c.session=Session(macID:owner.macID);c.moveHomeIfListed()
    check("owner 자동 home 이동은 준비 단계에서 중지", c.homeEligible == 0)
    c.startMove(to:7,kind:.fromRemote,fallback:nil)
    check("owner home 이동 socket 생성 직전도 차단", c.moveCreated == 0)
}
for method in ["qr","code","cable","icloud"] {
    let legacy=record(method);let c=StreamClient();c.records=[legacy]
    check("기존 \(method) plain 도어의 업그레이드 요구 보존", c.homeDecision(row,macID:legacy.macID,tap:false) == .updateSill)
    _=c.dialRow(row,macID:legacy.macID,trust:.saved(pin:pin),tagNamed:true)
    check("기존 \(method) row 경로 보존", c.rowConnections == 1 && c.remoteRequests.isEmpty)
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
}
print("Owner session routing \(checks)개, 실패 \(failures)개. 실제 후보/진입 메서드와 I/O 대역 검사.")
if failures != 0 { exit(1) }
