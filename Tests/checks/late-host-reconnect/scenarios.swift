var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ text: String) {
    checks += 1
    if ok() { print("PASS \(text)") } else { failures += 1; print("FAIL \(text)") }
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed(); Clock.advance(300)
    check(c.remoteDials.count > 14 && c.remoteDials.last! > 220 && c.reconnect?.remoteAllowed == true,
          "Vision owner whileRequested는 120초 이후에도 기존 TCP 재시도를 유지한다")
    check(Clock.pending == 1, "기존 재접속 타이머 한 개만 유지한다")
    let before = c.remoteDials.count
    for _ in 0..<10 { c.reconnectIfListed() }
    check(c.remoteDials.count == before && Clock.pending == 1, "반복 관측은 타이머나 요청을 복제하지 않는다")
    c.background(); Clock.advance(300)
    check(Clock.pending == 0 && c.remoteDials.count == before, "background는 요청과 재시도를 중단한다")
    c.foreground(); Clock.advance(10)
    check(c.remoteDials.count > before && Clock.pending == 1, "실제 foreground는 기존 whileRequested 의도를 이어간다")
    c.disconnect()
    let stopped = c.remoteDials.count
    Clock.advance(20)
    check(c.reconnect == nil && Clock.pending == 0 && c.startupStopped() && c.remoteDials.count == stopped,
          "사용자 종료 후 기존 예약 callback은 새 요청 없이 끝나고 startup도 중단한다")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.onDial = { _ in }
    c.reconnectIfListed(); Clock.advance(3)
    c.remoteDial = nil; c.session = Session(macID: c.targetID, candidate: c.candidate)
    let peer = NWConnection(); c.connection = peer; c.armProductionDeadline(peer)
    let deadline = c.firstListDeadline!
    Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.reconnect?.remoteAllowed == true && c.reconnect?.remoteFailures == 1 && Clock.pending == 1,
          "noWindowList는 개별 요청 deadline 후 transport 재시도를 유지한다")
    let retries = c.reconnect?.remoteFailures
    deadline.body(); c.connectionLost(peer, end: .noWindowList)
    check(c.reconnect?.remoteFailures == retries && Clock.pending == 1, "늦은 deadline과 종료 callback은 재시도를 복제하지 않는다")
    c.onDial = nil; Clock.advance(300)
    check(c.remoteDials.last! > 220 && Clock.pending == 1, "noWindowList 뒤 전체 Vision 의도는 120초에서 끝나지 않는다")
    c.disconnect(); let stopped = c.remoteDials.count; Clock.advance(20)
    check(Clock.pending == 0 && c.remoteDials.count == stopped, "사용자 종료 뒤 noWindowList 예약 callback은 새 요청 없이 끝난다")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed()
    let old = NWConnection(); c.connection = old; c.armProductionDeadline(old)
    let current = NWConnection(); c.connection = current
    Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.connection === current && c.remoteDials.isEmpty, "이전 peer deadline은 교체된 session을 종료하지 않는다")
    c.connected = true; c.armProductionDeadline(current); Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.connected && c.connection === current, "인정된 session은 첫 목록 deadline으로 종료되지 않는다")
    c.disconnect()
}
for end: RemoteDialPolicy.End in [.tls(-9808), .tls(-9816), .tls(-9825), .tlsAfterReady(-9829), .notSill,
                                 .dns(RemoteDialPolicy.dnsPolicyDenied), .goodbye(Goodbye.internetOff),
                                 .goodbye(Goodbye.remoteOff), .goodbye(Goodbye.removed)] {
    Clock.reset()
    let c = StreamClient(); c.seed(); c.onDial = { $0.fail([end]) }; c.reconnectIfListed(); Clock.advance(10)
    let count = c.remoteDials.count
    for _ in 0..<3 {
        c.pathSignature += "-new"; c.reconnectIfListed(); c.background(); c.foreground(); c.foreground()
        c.macs = [FoundMac(macID: c.targetID)]; c.sightings.since["Mac"] = Clock.now; c.discoveryChanged()
        Clock.advance(200)
    }
    check(count == 1 && c.remoteDials.count == count && Clock.pending == 0,
          "terminal \(end)는 경로·발견·실제/반복 foreground·startup에서 부활하지 않는다")
}
for end: RemoteDialPolicy.End in [.tls(-9816), .tlsAfterReady(-9829), .dns(RemoteDialPolicy.dnsPolicyDenied)] {
    for wasConnected in [false, true] {
        Clock.reset()
        let c = StreamClient(); c.seed(); c.connected = wasConnected
        c.session = Session(macID: c.targetID, candidate: c.candidate)
        c.sessionEnded(error: nil, end: end)
        c.background(); c.foreground(); c.discoveryChanged(); Clock.advance(300)
        check(c.reconnect == nil && c.remoteDials.isEmpty && Clock.pending == 0,
              "sessionEnded terminal \(end), connected=\(wasConnected)는 명시 중단을 보존한다")
    }
}
for route: Session.Route in [.network, .remote] {
    for reason in [Goodbye.quit, Goodbye.busy, Goodbye.remoteOff, Goodbye.internetOff, Goodbye.removed,
                   Goodbye.pairingRequired, Goodbye.update, "unknown"] {
        for wireReconnect: Bool? in [false, nil, true] {
            for wasConnected in [false, true] {
                Clock.reset()
                let c = StreamClient(); c.seed(); c.connected = wasConnected
                c.session = Session(route: route, macID: c.targetID, candidate: c.candidate)
                if route == .network { c.session?.home = .saved(pin: c.saved.fingerprintData!) }
                let goodbye = Goodbye(reason: reason, reconnect: wireReconnect)
                let expected = GoodbyePolicy.outcome(goodbye, mac: "Mac", device: StreamClient.deviceWord, saved: true)
                c.goodbye = goodbye; c.sessionEnded(error: nil, end: nil)
                let allowed = expected.reconnect && expected.remoteAllowed
                check((c.reconnect?.remoteAllowed == true) == allowed,
                      "\(route) Goodbye \(reason) wire=\(String(describing: wireReconnect)) connected=\(wasConnected)는 기존 정책을 따른다")
                if reason == Goodbye.removed { check(c.saved.revoked == true, "인증된 제거는 폐기를 보존한다") }
                c.disconnect()
            }
        }
    }
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.onDial = { $0.fail([.posix(ECONNREFUSED), .tls(-9816)]) }
    c.reconnectIfListed(); Clock.advance(300); c.background(); c.foreground()
    check(c.remoteDials.count == 1 && Clock.pending == 0, "같은 refused 표시여도 TCP와 TLS가 섞이면 stop이다")
}
Clock.reset()
do {
    let c = StreamClient(owner: false); c.seed(); c.reconnectIfListed(); Clock.advance(300)
    check(c.remoteDials.last! > 220 && c.reconnect?.remoteAllowed == true && Clock.pending == 1,
          "non-owner Vision saved Mac의 기존 whileRequested도 바꾸지 않는다")
    c.disconnect()
}
Clock.reset()
do {
    let c = StreamClient()
    c.visionStartupForeground = false
    check(!c.beginVisionSavedMacReconnect(c.saved) && c.reconnect == nil, "창 foreground 권리 없이 saved reconnect를 시작하지 않는다")
    c.visionStartupForeground = true; c.appInForeground = false
    check(!c.beginVisionSavedMacReconnect(c.saved), "앱 background에서는 saved reconnect를 시작하지 않는다")
    c.appInForeground = true
    check(c.beginVisionSavedMacReconnect(c.saved), "정당한 foreground 창은 기존 saved reconnect를 시작한다")
    c.reconnectIfListed(); check(Clock.pending == 1, "정당한 창이 타이머 한 개를 소유한다")
    c.retireVisionWindow(); c.foreground(); c.pathSignature = "cellular"; c.discoveryChanged(); Clock.advance(300)
    check(c.visionWindowRetired && !c.appInForeground && c.reconnect == nil && Clock.pending == 0 && c.remoteDials.isEmpty,
          "종료 창은 foreground·startup·재시도 권리를 되찾지 않는다")
    check(!c.beginVisionSavedMacReconnect(c.saved), "종료 창은 새 reconnect 의도를 만들지 않는다")
}
Clock.reset()
do {
    let first = StreamClient(); let second = StreamClient()
    first.seed(); second.seed(); first.reconnectIfListed(); second.reconnectIfListed()
    first.retireVisionWindow(); Clock.advance(3)
    check(first.remoteDials.isEmpty && !second.remoteDials.isEmpty && Clock.pending == 1,
          "한 창 종료는 다른 session의 의도·타이머를 건드리지 않는다")
    second.disconnect(); let stopped = second.remoteDials.count; Clock.advance(20)
    check(Clock.pending == 0 && second.remoteDials.count == stopped, "남은 창 종료 후 기존 callback은 재접속 없이 끝난다")
}
Clock.reset()
do {
    let c = StreamClient(); c.armStartup(); let stale = c.startupClosure()
    c.stopSavedMacAutoConnect(); stale(); c.background(); c.foreground(); c.discoveryChanged(); Clock.advance(300)
    check(c.startupStopped() && c.reconnect == nil && c.remoteDials.isEmpty && Clock.pending == 0,
          "중지된 startup은 이전 foreground closure로 부활하지 않는다")
}
Clock.reset()
do {
    let c = StreamClient(); c.armStartup(); let stale = c.startupClosure()
    Clock.advance(3); c.onDial = { $0.fail([.tls(-9816)]) }; c.fail([.tls(-9816)])
    stale(); c.background(); c.foreground(); c.discoveryChanged(); Clock.advance(300)
    check(c.startupStopped() && c.reconnect?.remoteAllowed == false && c.remoteDials.count == 1 && Clock.pending == 0,
          "terminal 이후 이전 startup closure도 재시작하지 않는다")
}
print("RESULT \(checks - failures)/\(checks) passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
