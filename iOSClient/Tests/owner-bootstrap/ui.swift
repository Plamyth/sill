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
c.ingress11(); c.ingress12(); c.ingress13()
check("합성 UI도 14개 실제 수동 ingress의 부작용을 허용하지 않음", c.effects == 0)
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

let localReturn = "인증된 로컬 복귀로 원격 세션이 종료되었습니다."
for initiallyEmpty in [false, true] {
    for retry: Bool? in [nil, false] {
        let ended = StreamClient()
        ended.ownerBootstrap.arm(savedKeyPresent: !initiallyEmpty, preferredKeyPresent: false,
                                 hasRecords: !initiallyEmpty, explicitLaunch: false)
        ended.savedMacs = [saved]
        ended.startupAutoConnection = .attempted
        ended.cancelOwnerBootstrap()
        ended.connection = 1
        ended.connected = true
        let before = SavedMacs.encode(ended.savedMacs)
        let effects = ended.effects
        let goodbye = Goodbye(reason: "", message: localReturn, reconnect: retry)
        ended.endWithNotice(goodbye, session: .init(), saved: saved, name: saved.name)
        let view = ended.automaticConnectionPresentation
        check("저장 접속 종료는 최초 등록 중지로 표시하지 않음", view.title == "저장된 Mac 연결이 종료되었습니다")
        check("Host 인증복귀 notice 원문을 보존", view.detail == localReturn && ended.notice?.text == localReturn && ended.status == localReturn)
        check("nil/false terminal을 자동 재접속으로 바꾸지 않음", !view.busy && ended.reconnect == nil && ended.effects == effects)
        check("표시는 저장 신뢰와 취소 상태를 바꾸지 않음", SavedMacs.encode(ended.savedMacs) == before && ended.ownerBootstrap.phase == .stopped && ended.ownerBootstrap.begin() == nil)
        ended.notice = nil
        check("notice 없이 status만 남아도 종료 원인을 보존", ended.automaticConnectionPresentation.detail == localReturn)
        ended.status = StreamClient.lookingOnNetwork
        check("원인 없는 기본 상태는 미확인으로 표시", ended.automaticConnectionPresentation.detail.contains("미확인"))
    }
}
let terminal = StreamClient()
terminal.savedMacs = [saved]
terminal.ownerBootstrap.arm(savedKeyPresent: true, preferredKeyPresent: false, hasRecords: true, explicitLaunch: false)
terminal.cancelOwnerBootstrap()
terminal.startupAutoConnection = .attempted
let unknown = Goodbye(reason: "")
let unknownOutcome = GoodbyePolicy.outcome(unknown, mac: saved.name, device: "iPad", saved: true)
terminal.endWithNotice(unknown, session: .init(), saved: saved, name: saved.name)
check("메시지 없는 unknown terminal도 실제 정책 문구 유지", terminal.automaticConnectionPresentation.detail == unknownOutcome.text && !terminal.automaticConnectionPresentation.busy && terminal.reconnect == nil)
for active in [0, 1, 2] {
    terminal.connection = active == 0 ? 1 : nil
    terminal.remoteDial = active == 1 ? 1 : nil
    terminal.reconnect = active == 2 ? .init(remoteAllowed: true) : nil
    terminal.status = "저장된 Mac에 다시 연결하는 중…"
    check("실제 connection/remoteDial/reconnect는 오래된 notice보다 우선", terminal.automaticConnectionPresentation.busy && terminal.automaticConnectionPresentation.detail == terminal.status)
}
terminal.connection = nil; terminal.remoteDial = nil; terminal.notice = nil
let loss = GoodbyePolicy.outcome(nil, mac: saved.name, device: "iPad", saved: true)
terminal.status = loss.text
terminal.reconnect = loss.reconnect ? .init(remoteAllowed: loss.remoteAllowed) : nil
check("일시 network loss의 기존 재접속과 원인 표시 유지", terminal.automaticConnectionPresentation.busy && terminal.automaticConnectionPresentation.detail == loss.text && terminal.reconnect?.remoteAllowed == true)
terminal.reconnect = .init(remoteAllowed: false)
check("원격 재접속 불허 우선순위 유지", !terminal.automaticConnectionPresentation.busy && terminal.automaticConnectionPresentation.title.contains("원격") && terminal.automaticConnectionPresentation.detail == loss.text)
terminal.reconnect = nil
for newKey in [false, true] {
    var rejected = saved
    if newKey { rejected.newKey = true } else { rejected.revoked = true }
    terminal.savedMacs = [rejected]
    terminal.status = GoodbyePolicy.outcome(Goodbye(reason: Goodbye.removed), mac: saved.name, device: "iPad", saved: true).text
    terminal.connection = 1
    check("취소된 bootstrap에서도 removed/newKey 보호가 접속 표시보다 우선", !terminal.automaticConnectionPresentation.busy && terminal.automaticConnectionPresentation.title.contains("신뢰"))
}
check("처음 빈 저장소의 명시 취소는 등록 중지로 구별", c.automaticConnectionPresentation.title == "소유 Mac 자동 등록이 중지되었습니다" && !c.automaticConnectionPresentation.busy && c.ownerBootstrap.phase == .stopped)
let startup = StreamClient()
startup.savedMacs = [saved]
startup.ownerBootstrap.arm(savedKeyPresent: true, preferredKeyPresent: false, hasRecords: true, explicitLaunch: false)
startup.startupAutoConnection = .waiting(saved.macID)
startup.mockPinned = true
startup.trySavedMacAutoConnect()
check("최초 검색은 아직 유선 후보가 없으면 대기 유지", startup.automaticConnectionPresentation.busy && startup.connection == nil && startup.effects == 0)
startup.macs = [FoundMac(macID: saved.macID)]
startup.trySavedMacAutoConnect()
check("실제 startup caller의 유선 dial은 첫 목록 전 connection으로 진행 표시", startup.automaticConnectionPresentation.busy && startup.automaticConnectionPresentation.detail == "합성 Mac에 연결하는 중…" && startup.connection != nil && !startup.connected && startup.ownerBootstrap.phase == .stopped)
let terminalWords = "합성 Mac에 연결하려면 이제 페어링이 필요합니다. Mac을 탭해 이 iPad와 페어링하세요."
let startupEffects = startup.effects
let savedBefore = SavedMacs.encode(startup.savedMacs)
startup.endAtHome(terminalWords)
print("WIRED_PAIRING_TERMINAL busy=\(startup.automaticConnectionPresentation.busy) detailPreserved=\(startup.automaticConnectionPresentation.detail == terminalWords) connection=\(String(describing: startup.connection)) reconnect=\(String(describing: startup.reconnect))")
check("최초 목록 전 pairingRequired 종료는 남은 wired로 대기를 표시하지 않음", !startup.automaticConnectionPresentation.busy && startup.automaticConnectionPresentation.detail == terminalWords && startup.connection == nil && startup.reconnect == nil && startup.notice == nil)
startup.trySavedMacAutoConnect()
check("종료된 wired는 표시 조회나 검색으로 자동 재접속하지 않음", startup.effects == startupEffects && SavedMacs.encode(startup.savedMacs) == savedBefore && startup.ownerBootstrap.phase == .stopped)
for foreground in [false, true] {
    let fallback = StreamClient()
    fallback.savedMacs = [saved]
    fallback.ownerBootstrap.arm(savedKeyPresent: true, preferredKeyPresent: false, hasRecords: true, explicitLaunch: false)
    fallback.startupAutoConnection = .waiting(saved.macID)
    fallback.mockPinned = true
    fallback.macs = [FoundMac(macID: saved.macID)]
    fallback.trySavedMacAutoConnect()
    fallback.appInForeground = foreground
    check("실제 유선 fallback caller는 최초 목록 전 경로를 한 번 전환", fallback.fallBackFromStartupWired())
    if !foreground {
        check("비활성 fallback은 waitingRemote로 대기 표시", fallback.automaticConnectionPresentation.busy && fallback.remoteDial == nil && fallback.connection == nil)
        fallback.appInForeground = true
        fallback.trySavedMacAutoConnect()
    }
    check("새 무선 fallback의 실제 reconnect와 remoteDial은 진행 표시", fallback.automaticConnectionPresentation.busy && fallback.automaticConnectionPresentation.detail == "합성 Mac에 원격 연결하는 중…" && fallback.remoteDial != nil && fallback.reconnect?.remoteAllowed == true)
    check("유선 fallback은 같은 startup에서 반복되지 않음", !fallback.fallBackFromStartupWired())
}
print("PASS \(count) owner UI presentation and ingress guard checks; actual extracted code, no SwiftUI/device/network/Keychain effects")
