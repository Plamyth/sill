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
    let before = c.browserIdentity(); c.background(); c.foreground()
    check(c.browserIdentity() != before, "foreground rebuilds browser even without a reported mDNS failure")
    c.failBrowser(); Clock.advance(1.1); c.failBrowser(); Clock.advance(2.1); c.failBrowser()
    Clock.advance(3.1)
    check(c.rows() == ["Mac"], "failed replacement keeps rows beyond old settle deadline")
    Clock.advance(1.1); c.report(["Fresh"]); Clock.advance(3.1)
    check(c.rows() == ["Fresh"], "successful replacement expires stale kept rows")
}
print("Reconnect glue: \(checks - failures)/\(checks) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
