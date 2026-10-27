var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ text: String) {
    checks += 1
    if ok() { print("PASS \(text)") } else { failures += 1; print("FAIL \(text)") }
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed(); Clock.advance(5000)
    let attempts = c.remoteDials.count
    check(c.remoteDials == [103, 105, 109, 117, 127, 137, 147, 157, 167, 177, 187, 197, 207, 217], "owner preserves existing 2/4/8/10-second backoff throughout the original 120-second budget")
    check(attempts == 14, "owner retains all existing attempts within the unchanged recovery window; got \(attempts)")
    check(Clock.pending == 0, "exhausted owner budget leaves no timer")
    check(c.reconnect?.remoteAllowed == true, "budget exhaustion does not become terminal trust refusal")
    c.pathSignature = "cellular"; c.reconnectIfListed(); Clock.advance(3)
    check(c.remoteDials.count > attempts, "new path resumes finite owner recovery after 120 seconds")
    let afterPath = c.remoteDials.count
    for _ in 0..<10 { c.reconnectIfListed() }
    check(c.remoteDials.count == afterPath && Clock.pending == 1, "same path observations do not reset budget or duplicate timer")
    c.background(); Clock.advance(500)
    check(Clock.pending == 0, "background cancels every owner retry")
    c.foreground(); Clock.advance(3)
    check(c.remoteDials.count > afterPath, "real foreground transition resumes finite owner recovery")
    let resumed = c.remoteDials.count
    c.foreground(); c.reconnectIfListed()
    check(c.remoteDials.count == resumed, "duplicate foreground does not reset owner recovery")
    Clock.advance(500); let exhausted = c.remoteDials.count
    c.macs = [FoundMac(macID: c.targetID)]; c.sightings.since["Mac"] = Clock.now
    c.onDial = { client in client.remoteDial = nil; client.connected = true; client.reconnect = nil }
    c.reconnectIfListed()
    check(c.connected && c.remoteDials.count == exhausted + 1, "fresh matching Host discovery restores existing owner trust after 120 seconds")
    check(Clock.pending == 0, "successful recovery leaves no retry timer")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.onDial = { _ in }
    c.reconnectIfListed(); Clock.advance(3)
    c.remoteDial = nil; c.session = Session(macID: c.targetID, candidate: c.candidate)
    let peer = NWConnection(); c.connection = peer
    c.armProductionDeadline(peer)
    let deadline = c.firstListDeadline!
    Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.reconnect?.remoteAllowed == true && c.reconnect?.remoteFailures == 1 && Clock.pending == 1,
          "actual first-catalog deadline through endSession/sessionEnded retains finite retry on noAnswer")
    let retries = c.reconnect?.remoteFailures
    deadline.body(); c.connectionLost(peer, end: .noWindowList)
    check(c.reconnect?.remoteFailures == retries && Clock.pending <= 1,
          "duplicate deadline and ended-peer callbacks do not add retries")
    c.onDial = nil; Clock.advance(500)
    let attempts = c.remoteDials.count
    check(attempts > 1 && c.reconnect?.remoteAllowed == true && Clock.pending == 0,
          "first-catalog timeout exhausts the existing finite budget without revoking trust or polling")
    c.onDial = { client in client.connected = true; client.remoteDial = nil; client.reconnect = nil }
    c.pathSignature = "cellular"; c.reconnectIfListed(); Clock.advance(3)
    check(c.connected && c.remoteDials.count == attempts + 1 && Clock.pending == 0,
          "new path after first-catalog timeout restores existing trust once")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed()
    let old = NWConnection(); c.connection = old; c.armProductionDeadline(old)
    let current = NWConnection(); c.connection = current
    Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.connection === current && c.remoteDials.isEmpty,
          "stale first-catalog deadline cannot end the replacement peer")
    c.connected = true; c.armProductionDeadline(current)
    Clock.advance(RemoteDialPolicy.firstListDeadline)
    check(c.connected && c.connection === current && c.remoteDials.isEmpty,
          "first-catalog deadline cannot end an admitted session")
}
for end: RemoteDialPolicy.End in [.tls(-9808), .tls(-9816), .tls(-9825), .tlsAfterReady(-9829), .notSill,
                                 .goodbye(Goodbye.internetOff), .goodbye(Goodbye.remoteOff), .goodbye(Goodbye.removed)] {
    Clock.reset()
    let c = StreamClient(); c.seed(); c.onDial = { $0.fail([end]) }; c.reconnectIfListed(); Clock.advance(10)
    let count = c.remoteDials.count
    c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); Clock.advance(200); c.foreground()
    c.macs = [FoundMac(macID: c.targetID)]; c.sightings.since["Mac"] = Clock.now; c.reconnectIfListed(); Clock.advance(500)
    check(count == 1 && c.remoteDials.count == count && Clock.pending == 0, "terminal \(end) cannot resume on path/foreground/discovery")
}
for reason in [Goodbye.remoteOff, Goodbye.internetOff, Goodbye.removed, Goodbye.pairingRequired, Goodbye.update, "unknown"] {
    for reconnect: Bool? in [false, nil] {
        Clock.reset()
        let c = StreamClient(); c.seed(); c.session = Session(macID: c.targetID, candidate: c.candidate)
        c.goodbye = Goodbye(reason: reason, reconnect: reconnect)
        c.sessionEnded(error: nil, end: nil)
        if reason == Goodbye.removed { check(c.saved.revoked == true, "authenticated removal retains persistent revocation") }
        c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); c.foreground(); Clock.advance(500)
        check(c.remoteDials.isEmpty && Clock.pending == 0, "explicit Goodbye \(reason) reconnect=\(String(describing: reconnect)) never resumes owner")
    }
}
for reason in [Goodbye.quit, Goodbye.busy] {
    for wireReconnect: Bool? in [false, nil] {
        for wasConnected in [false, true] {
            Clock.reset()
            let c = StreamClient(); c.seed(); c.connected = wasConnected
            c.session = Session(macID: c.targetID, candidate: c.candidate)
            c.goodbye = Goodbye(reason: reason, reconnect: wireReconnect)
            c.sessionEnded(error: nil, end: nil)
            check(c.reconnect?.remoteAllowed == true, "known \(reason) wire=\(String(describing: wireReconnect)) connected=\(wasConnected) preserves GoodbyePolicy reconnect")
            Clock.advance(4)
            c.macs = [FoundMac(macID: c.targetID)]; c.sightings.since["Mac"] = Clock.now
            c.onDial = { client in client.remoteDial = nil; client.connected = true; client.reconnect = nil }
            c.reconnectIfListed()
            check(c.connected && Clock.pending == 0, "new Host discovery restores known \(reason) session using finite recovery")
        }
    }
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.onDial = { $0.fail([.posix(ECONNREFUSED), .tls(-9816)]) }
    c.reconnectIfListed(); Clock.advance(500); c.pathSignature = "cellular"; c.reconnectIfListed()
    check(c.remoteDials.count == 1 && Clock.pending == 0, "transport plus TLS refusal is terminal even with same displayed refused")
}
for invalid in ["key", "pin", "revoked", "newKey"] {
    Clock.reset(); DeviceIdentity.available = invalid != "key"
    let c = StreamClient(); c.seed()
    if invalid == "pin" { c.saved.fingerprint = Base64URL.encode(Data(repeating: 9, count: 32)) }
    if invalid == "revoked" { c.saved.revoked = true }
    if invalid == "newKey" { c.saved.newKey = true }
    c.reconnectIfListed(); Clock.advance(500); c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); c.foreground()
    check(c.remoteDials.isEmpty && Clock.pending == 0, "invalid \(invalid) cannot dial or rearm")
    DeviceIdentity.available = true
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed()
    check(Clock.pending == 1, "user-stop precondition has exactly one scheduled retry")
    c.disconnect()
    check(c.reconnect == nil && Clock.pending == 0, "user disconnect cancels owner intent and scheduled timer immediately")
    c.pathSignature = "cellular"; c.background(); c.foreground(); c.reconnectIfListed(); Clock.advance(500)
    check(c.remoteDials.isEmpty && Clock.pending == 0, "user stop cannot resume on path or foreground")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed(); Clock.advance(5000)
    let count = c.remoteDials.count
    c.onDial = { client in client.connected = true; client.remoteDial = nil; client.reconnect = nil }
    Clock.advance(5000)
    check(!c.connected && c.remoteDials.count == count && Clock.pending == 0, "same-path Host return without an existing event remains undetectable after exhaustion")
    c.pathSignature = "cellular"; c.reconnectIfListed(); Clock.advance(3)
    check(c.connected && c.remoteDials.count == count + 1, "external recovery event connects the returned Host with existing trust")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed()
    let a = FoundMac(name: "A", macID: c.targetID)
    let b = FoundMac(name: "B", macID: c.targetID)
    c.macs = [a, b]; c.sightings.since = ["A": 100, "B": 100]
    c.reconnectIfListed(); Clock.advance(500)
    let count = c.remoteDials.count
    for _ in 0..<3 {
        c.macs = [b, a]; c.reconnectIfListed()
        c.macs = [a, b]; c.reconnectIfListed()
    }
    check(c.remoteDials.count == count && Clock.pending == 0, "reordering already observed Host listings cannot replenish exhausted budget")
    c.sightings.since["A"] = Clock.now; c.reconnectIfListed()
    check(c.remoteDials.count == count + 1, "new trust-bound discovery generation replenishes the existing budget once")
    let resumed = c.remoteDials.count
    for _ in 0..<3 { c.reconnectIfListed() }
    check(c.remoteDials.count == resumed && Clock.pending == 1, "duplicate discovery generation does not replenish again")
    c.sightings.since["A"] = 100; c.reconnectIfListed()
    check(c.remoteDials.count == resumed && Clock.pending == 1, "stale discovery generation cannot replenish current budget")
    c.disconnect()
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed(); Clock.advance(500)
    let count = c.remoteDials.count
    c.macs = [FoundMac(name: "Mac", macID: nil, carriesTag: false)]
    c.sightings.since["Mac"] = Clock.now; c.reconnectIfListed()
    check(c.remoteDials.count == count && Clock.pending == 0, "name-only discovery cannot replenish trusted owner recovery")
}
Clock.reset()
do {
    let c = StreamClient(owner: false); c.seed(); c.reconnectIfListed(); Clock.advance(400)
    let count = c.remoteDials.count
    c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); c.foreground(); Clock.advance(500)
    check(c.remoteDials.count == count && c.reconnect?.remoteAllowed == false && Clock.pending == 0, "legacy retains original 120-second cutoff across external events")
}
print("RESULT \(checks - failures)/\(checks) passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
