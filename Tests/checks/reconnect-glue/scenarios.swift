var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

Clock.reset()
do {
    let c = StreamClient(); c.seed(saved: false)
    c.scheduleReconnectRetry(); c.reconnectIfListed()
    Clock.advance(350)
    check(c.rowDials.count == 12, "listed sleeping host receives exactly 12 dials, observed \(c.rowDials.count)")
    check(c.rowDials == [100,105,115,135,165,195,225,255,285,315,345,375], "listed dials follow upstream 5/10/20/30 second starts")
    Clock.advance(500)
    check(Clock.pending == 0, "exhausted listed budget leaves no repeating timer")
    c.sightings.since["Mac"] = Clock.now
    c.reconnectIfListed()
    check(c.rowDials.count == 13, "fresh row evidence resumes exhausted listing")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.macs = []; c.background()
    c.reconnectIfListed(); c.scheduleReconnectRetry()
    Clock.advance(25)
    check(c.remoteDials.isEmpty, "native background gate also prevents remote attempts")
    check(Clock.pending == 0, "background leaves no retry chain")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.macs = []
    c.reconnectIfListed(); c.scheduleReconnectRetry()
    Clock.advance(160)
    check(!c.remoteDials.isEmpty && c.remoteDials.allSatisfy { $0 < 220 }, "automatic remote attempts stop at original 120 second window")
    check(Clock.pending == 0, "expired remote window leaves no polling timer")
}
Clock.reset()
do {
    let c = StreamClient(); c.startBrowsing(); c.report(["Mac"]); Clock.advance(0)
    let before = c.browserHandle(); c.background(); c.foreground()
    check(c.browserHandle() !== before, "foreground rebuilds browser even without a reported mDNS failure")
    c.failBrowser(); Clock.advance(1.1); c.failBrowser(); Clock.advance(2.1); c.failBrowser()
    Clock.advance(3.1)
    check(c.rows() == ["Mac"], "failed replacement keeps rows beyond old settle deadline")
    Clock.advance(1.1); c.report(["Fresh"]); Clock.advance(3.1)
    check(c.rows() == ["Fresh"], "successful replacement expires stale kept rows")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.reconnectIfListed()
    let lost = c.reconnect!.lostAt
    c.session = Session(why: nil)
    Clock.advance(1); c.finishRowFailure()
    check(c.reconnect?.lostAt == lost && c.reconnect?.rowDials == 1, "failed row dial preserves original loss and consumed budget")
    check(c.rowDials == [100], "failed row dial cannot redial immediately before its due time")
    Clock.advance(4)
    check(c.rowDials == [100,105], "failed row dial resumes at original due time")
    c.background(); let count = c.rowDials.count
    Clock.advance(100)
    check(c.rowDials.count == count && c.connection == nil && Clock.pending == 0, "background cancels pending automatic row and ends timer chain")
    c.foreground()
    check(c.rowDials.count == count + 1 && c.reconnect?.rowDials == 1, "new foreground evidence resets listed count and resumes once")
    c.foreground()
    check(c.rowDials.count == count + 1, "repeated foreground notification cannot reset active attempt")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.macs = []; c.reconnectIfListed()
    let count = c.remoteDials.count
    c.background(); Clock.advance(30)
    check(c.remoteDial == nil && c.remoteDials.count == count && Clock.pending == 0, "background cancels automatic remote connector and retry chain")
    c.foreground()
    check(c.remoteDials.count == count + 1, "foreground resumes remote within original window")
    c.background(); Clock.advance(150); c.foreground(); Clock.advance(2)
    check(c.remoteDials.count == count + 1 && c.reconnect?.remoteAllowed == false && Clock.pending == 0, "foreground does not extend expired remote window")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(saved: false); c.reconnectIfListed()
    Clock.advance(350)
    let count = c.rowDials.count
    for _ in 0..<3 { c.reconnectIfListed(); c.scheduleReconnectRetry() }
    check(c.rowDials.count == count && Clock.pending == 0, "same listing and repeated evaluations cannot restart exhausted budget")
    c.seed(saved: false); c.reconnectIfListed()
    check(c.rowDials.count == count + 1, "new user intent may start a fresh reconnect value")
}
Clock.reset()
do {
    let c = StreamClient(); c.seed(); c.connected = true; c.reconnectIfListed()
    check(c.rowDials.isEmpty && c.remoteDials.isEmpty, "connected session receives no automatic attempt")
    c.connected = false; c.moveUnderWay = true; c.reconnectIfListed()
    check(c.rowDials.isEmpty && c.remoteDials.isEmpty, "path move blocks automatic reconnect")
    c.moveUnderWay = false; c.decision = .waitForTap; c.reconnectIfListed()
    check(c.reconnect == nil && c.rowDials.isEmpty && Clock.pending == 0, "pairing or revoked row ends reconnect without a dial")
}
Clock.reset()
do {
    let c = StreamClient(); c.startBrowsing(); c.report(["Mac"]); Clock.advance(0)
    let old = c.browserHandle()!
    c.background(); c.failBrowser(); Clock.advance(50)
    check(c.browserHandle() === old && Clock.pending == 0, "failed browser cannot rebuild or poll in background")
    c.foreground(); let fresh = c.browserHandle()!
    old.browseResultsChangedHandler?([NWBrowser.Result(name: "Obsolete")], [])
    old.stateUpdateHandler?(.failed(.dns(-65569))); Clock.advance(0)
    check(c.browserHandle() === fresh && c.rows() == ["Mac"], "replaced browser callbacks cannot mutate current rows or life")
    Clock.advance(3.1)
    check(c.rows().isEmpty, "foreground keeps old rows only for bounded settle interval")
}
check(DiscoveryPolicy.rebuildBrowser(failedAt: nil, failures: 0, cameForward: true, foreground: false, now: Clock.now).rebuild == false,
      "browser policy also refuses inconsistent foreground evidence")
print("Reconnect glue: \(checks - failures)/\(checks) passed, \(failures) failed")
typealias P = DiscoveryPolicy
var policyCount = 0
var policyFailures = 0
func check(_ name: String, _ condition: Bool) {
    policyCount += 1
    if !condition { failures += 1; policyFailures += 1; print("FAIL upstream policy \(name)") }
}
afterSleepPolicy()
print("Upstream sleep policy subset: \(policyCount - policyFailures)/\(policyCount) passed, \(policyFailures) failed")
exit(failures == 0 ? 0 : 1)
