
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
print("\(checks - failures)/\(checks) checks passed; \(failures) failed")
exit(failures == 0 ? 0 : 1)
