var count = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    precondition(condition(), name)
    count += 1
}
let pin = Data(repeating: 0x37, count: 32)
let saved = SavedMac(macID: MacID.make(fingerprint: pin), fingerprint: Base64URL.encode(pin),
                     name: "합성 Mac", recognitionKey: Base64URL.encode(Data(repeating: 0x12, count: 32)),
                     remotePort: 7455, addresses: [], infoIssuedAt: 0, lastWorked: nil,
                     pairedAt: Date(), method: OwnerMacBootstrap.method, homeTLS: true)
UserDefaults.standard.removeObject(forKey: StreamClient.preferredTrustedMacKey)
defer { UserDefaults.standard.removeObject(forKey: StreamClient.preferredTrustedMacKey) }
let c = StreamClient()
check("release와 DEBUG 실제 iOS는 수동 통신 불허", !StreamClient.manualPairingEnabled)
check("실제 클라이언트의 수동 UI 불허", !c.manualPairingUIEnabled)
c.mockDiscovery = true
#if DEBUG
check("DEBUG 합성 화면만 수동 UI 허용", c.manualPairingUIEnabled)
#else
check("release는 합성 필드로도 수동 UI 불허", !c.manualPairingUIEnabled)
#endif
c.ingress0(); c.ingress1(); c.ingress2(); c.ingress3(); c.ingress4(); c.ingress5()
c.ingress6(); c.ingress7(); c.ingress8(); c.ingress9(); c.ingress10()
check("합성 UI도 11개 실제 수동 ingress의 부작용을 허용하지 않음", c.effects == 0)
let ingress = StreamClient()
ingress.ownerBootstrap.arm(savedKeyPresent: false, preferredKeyPresent: false, hasRecords: false, explicitLaunch: false)
let ingressToken = ingress.ownerBootstrap.begin()!
let initialStatus = ingress.status
ingress.handleOpenURL(URL(string: "sill://pair?untrusted=value")!)
check("실제 외부 링크 본문은 bootstrap과 pending 상태를 바꾸지 않음", ingress.ownerBootstrap.phase == .dialing(ingressToken) && ingress.pendingLink == nil && ingress.pairing == .idle && ingress.status == initialStatus)
check("실제 dial의 ask 분기는 false로 반환", !ingress.dial(FoundMac(), macID: nil, tap: true))
check("ask 차단은 bootstrap 취소와 통신을 하지 않음", ingress.ownerBootstrap.phase == .dialing(ingressToken) && ingress.effects == 0)
ingress.ownerBootstrap.cancel()
ingress.handleOpenURL(URL(string: "sill://pair?untrusted=value")!)
check("외부 링크는 STOPPED를 되살리지 않음", ingress.ownerBootstrap.phase == .stopped && ingress.pendingLink == nil)
check("준비는 spinner 없음", !c.automaticConnectionPresentation.busy)
c.ownerBootstrap.arm(savedKeyPresent: false, preferredKeyPresent: false, hasRecords: false, explicitLaunch: false)
let ready = c.automaticConnectionPresentation
check("준비 대기와 진행을 구분", !ready.busy && ready.title.contains("대기"))
let token = c.ownerBootstrap.begin()!
let dialing = c.automaticConnectionPresentation
check("연결 중에만 진행 표시", dialing.busy && dialing.title != ready.title)
check("교환 시작", c.ownerBootstrap.exchange(token))
let exchanging = c.automaticConnectionPresentation
check("등록 교환은 연결과 구별", exchanging.busy && exchanging.title != dialing.title)
check("실패 완료", c.ownerBootstrap.finish(token))
c.status = "소유 Mac의 자동 연결 승인을 확인하지 못했습니다."
let failed = c.automaticConnectionPresentation
check("실패는 spinner 없이 실제 오류 보존", !failed.busy && failed.detail == c.status)
c.ownerBootstrap.cancel()
let stopped = c.automaticConnectionPresentation
check("중지는 실패와 구분하고 spinner 없음", !stopped.busy && stopped.title != failed.title)
c.ownerBootstrap.foreground(savedKeyPresent: false, preferredKeyPresent: false, hasRecords: false)
check("표현 조회와 foreground로 STOPPED 복원 안함", c.ownerBootstrap.phase == .stopped)
let returning = StreamClient()
returning.savedMacs = [saved]
returning.ownerBootstrap.arm(savedKeyPresent: true, preferredKeyPresent: false, hasRecords: true, explicitLaunch: false)
returning.startupAutoConnection = .waiting(saved.macID)
check("저장 Mac 대기는 최초 등록과 구별", returning.automaticConnectionPresentation.busy && returning.automaticConnectionPresentation.title.contains("저장된"))
returning.startupAutoConnection = .attempted
returning.remoteDial = 1
check("저장 Mac 재접속 진행 표시", returning.automaticConnectionPresentation.busy)
returning.remoteDial = nil
returning.reconnect = .init(remoteAllowed: false)
returning.status = "Mac이 원격 접근을 중단했습니다."
check("terminal 재접속은 spinner 없이 원인 표시", !returning.automaticConnectionPresentation.busy && returning.automaticConnectionPresentation.detail == returning.status && returning.automaticConnectionPresentation.title.contains("원격"))
returning.reconnect = nil
returning.status = "기기 키를 읽을 수 없습니다."
check("키 오류는 완료 spinner 없이 원인 표시", !returning.automaticConnectionPresentation.busy && returning.automaticConnectionPresentation.detail == returning.status)
for newKey in [false, true] {
    var rejected = saved
    if newKey { rejected.newKey = true } else { rejected.revoked = true }
    returning.savedMacs = [rejected]
    let before = SavedMacs.encode(returning.savedMacs)
    let view = returning.automaticConnectionPresentation
    check("폐기·키 변경은 자동 등록 안내로 우회하지 않음", !view.busy && view.title.contains("신뢰"))
    check("상태 표시가 저장 신뢰를 변경하지 않음", SavedMacs.encode(returning.savedMacs) == before && returning.ownerBootstrap.phase == .finished)
}
let damaged = StreamClient()
damaged.ownerBootstrap.arm(savedKeyPresent: true, preferredKeyPresent: false, hasRecords: false, explicitLaunch: false)
check("원시 빈 배열·손상 저장소도 spinner 없이 대기", !damaged.automaticConnectionPresentation.busy && !damaged.ownerBootstrap.wasInitiallyEmpty)
print("PASS \(count) owner UI presentation and ingress guard checks; actual extracted code, no SwiftUI/device/network/Keychain effects")
