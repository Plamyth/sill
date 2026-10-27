var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ text: String) {
    checks += 1
    if ok() { print("PASS \(text)") } else { failures += 1; print("FAIL \(text)") }
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed(); Clock.advance(400)
    let attempts = c.remoteDials.count
    check(attempts > 0 && attempts <= 4, "owner has at most four attempts per unchanged recovery budget; got \(attempts)")
    check(Clock.pending == 0, "exhausted owner budget leaves no timer")
    check(c.reconnect?.remoteAllowed == true, "budget exhaustion does not become terminal trust refusal")
    c.pathSignature = "cellular"; c.reconnectIfListed(); Clock.advance(3)
    check(c.remoteDials.count > attempts, "new path resumes finite owner recovery after 120 seconds")
    let afterPath = c.remoteDials.count
    for _ in 0..<10 { c.reconnectIfListed() }
    check(c.remoteDials.count == afterPath, "same path observations do not reset budget or duplicate timer")
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
for end: RemoteDialPolicy.End in [.tls(-9808), .tls(-9816), .tls(-9825), .tlsAfterReady(-9829), .notSill, .noWindowList,
                                 .goodbye(Goodbye.internetOff), .goodbye(Goodbye.remoteOff), .goodbye(Goodbye.removed)] {
    Clock.reset()
    let c = StreamClient(); c.seed(); c.onDial = { $0.fail([end]) }; c.reconnectIfListed(); Clock.advance(10)
    let count = c.remoteDials.count
    c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); Clock.advance(200); c.foreground()
    c.macs = [FoundMac(macID: c.targetID)]; c.sightings.since["Mac"] = Clock.now; c.reconnectIfListed(); Clock.advance(500)
    check(count == 1 && c.remoteDials.count == count && Clock.pending == 0, "terminal \(end) cannot resume on path/foreground/discovery")
}
for reason in [Goodbye.quit, Goodbye.busy, Goodbye.remoteOff, Goodbye.internetOff, Goodbye.removed, "unknown"] {
    for reconnect: Bool? in [false, nil] {
        Clock.reset()
        let c = StreamClient(); c.seed(); c.session = Session(macID: c.targetID, candidate: c.candidate)
        c.goodbye = Goodbye(reason: reason, reconnect: reconnect)
        c.sessionEnded(error: nil, end: nil)
        c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); c.foreground(); Clock.advance(500)
        check(c.remoteDials.isEmpty && Clock.pending == 0, "explicit Goodbye \(reason) reconnect=\(String(describing: reconnect)) never resumes owner")
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
    let c = StreamClient(owner: false); c.seed(); c.reconnectIfListed(); Clock.advance(400)
    let count = c.remoteDials.count
    c.pathSignature = "cellular"; c.reconnectIfListed(); c.background(); c.foreground(); Clock.advance(500)
    check(c.remoteDials.count == count && c.reconnect?.remoteAllowed == false && Clock.pending == 0, "legacy retains original 120-second cutoff across external events")
}
print("RESULT \(checks - failures)/\(checks) passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
