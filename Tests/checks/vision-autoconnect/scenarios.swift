var failures = 0
var assertions = 0
setbuf(stdout, nil)
func check(_ name: String, _ value: @autoclosure () -> Bool) {
    assertions += 1
    if value() { print("ok " + name) } else { failures += 1; print("FAIL " + name) }
}
let pin = Data(repeating: 0x11, count: 32)
let otherPin = Data(repeating: 0x22, count: 32)
let service = "강태완의 MacBook\u{00A0}Pro · CCR Sill"
typealias Boot = VisionCableBootstrap<FoundMac>
let args = ["app", "--ccr-cable-bootstrap-pin", Base64URL.encode(pin), "--ccr-cable-bootstrap-service", service]
let launch = Boot.Launch.parse(args)
func row(_ name: String = service, wired: Bool = true, route: FoundMac.Route = .network,
         door: DiscoveryPolicy.HomeDoor = .pairingRequired, macID: String? = nil, tagged: Bool = false) -> FoundMac {
    FoundMac(name: name, endpoint: .service(name: name, type: "_sill._tcp", domain: "local.", interface: nil),
             route: route, macID: macID, carriesTag: tagged, method: wired ? .wired : .wifi,
             wired: wired ? NWInterface(name: "anri2") : nil, door: door)
}
func fresh(_ mode: Boot.Launch = launch) -> StreamClient {
    DeviceIdentity.available = true
    UserDefaults.standard.strings = [:]
    let client = StreamClient(mode)
    client.macs = [row()]
    return client
}
func accept(_ client: StreamClient, peerPin: Data = pin) {
    client.considerVisionCableBootstrap()
    client.homeDialer?.win(peerPin)
}
let result = PairResult(ok: true, macID: MacID.make(fingerprint: pin), name: "CCR Sill",
                        recognitionKey: Base64URL.encode(Data(repeating: 0x33, count: 32)), method: PairResult.cable)
check("both native public arguments parse exactly", launch == .cable(.init(pin: pin, service: service)))
check("ordinary launch has no bootstrap", Boot.Launch.parse(["app"]) == .ordinary)
for text in ["", "short", Base64URL.encode(pin) + "=", String(repeating: "+", count: 43), String(Base64URL.encode(pin).dropLast()) + "F"] {
    check("invalid or noncanonical public pin refused", Boot.Launch.parse([args[1], text, args[3], service]) == .invalid)
}
check("missing service refused", Boot.Launch.parse([args[1], args[2]]) == .invalid)
check("duplicate pin flag refused", Boot.Launch.parse(args + [args[1], args[2]]) == .invalid)
check("unknown bootstrap option refused", Boot.Launch.parse(["--ccr-cable-bootstrap-url", "https://example.invalid"]) == .invalid)
let ordinary = fresh(.ordinary)
ordinary.considerVisionCableBootstrap()
check("ordinary launch cannot create an identity or ask unknown Mac", ordinary.homeDialer == nil && ordinary.identityCalls == 0)
for candidate in [row("Other CCR Sill"), row(service.replacingOccurrences(of: "\u{00A0}", with: " ")), row(route: .direct), row(route: .remote)] {
    let client = fresh(); client.macs = [candidate]; client.considerVisionCableBootstrap()
    check("unrelated name, ASCII space, Direct and Remote cannot enroll", client.homeDialer == nil && client.identityCalls == 0)
}
let nonwired = fresh(); nonwired.macs = [row(wired: false)]; nonwired.considerVisionCableBootstrap()
check("exact nonwired row waits without enrollment", nonwired.homeDialer == nil && nonwired.visionCableBootstrap.phase == .waiting(.waitingForCable))
nonwired.macs = [row()]; nonwired.considerVisionCableBootstrap()
check("a subsequent actual wired listing may start the one attempt", nonwired.homeDialer != nil)
let duplicate = fresh(); duplicate.macs = [row(), row()]; duplicate.considerVisionCableBootstrap()
check("duplicate exact network instances refuse enrollment", duplicate.visionCableBootstrap.phase == .stopped(.duplicateService) && duplicate.homeDialer == nil)
for door in [DiscoveryPolicy.HomeDoor.plain, .open] {
    let client = fresh(); client.macs = [row(door: door)]; client.considerVisionCableBootstrap()
    check("only pairingRequired door accepted", client.homeDialer == nil && client.visionCableBootstrap.phase == .stopped(.pairingUnavailable))
}
for occupied in 0..<7 {
    let client = fresh()
    switch occupied {
    case 0: client.connected = true
    case 1: client.connection = NWConnection()
    case 2: client.reconnect = 1
    case 3: client.pairing = .working
    case 4: client.remoteDial = RemoteConnector()
    case 5: client.pairingDial = RemoteConnector()
    default:
        client.homeAsk = HomeAsk(target: .init(endpoint: row().endpoint!, label: "fixture"), name: "fixture", cableRow: false, savedID: nil, tagNamed: false)
    }
    client.considerVisionCableBootstrap()
    check("occupied client refuses startup pairing", client.homeDialer == nil && client.visionCableBootstrap.phase == .stopped(.occupied))
}
let denied = fresh(); denied.localNetworkDenied = true; denied.considerVisionCableBootstrap()
check("permission refusal records a fixed reason", denied.visionCableBootstrap.phase == .stopped(.permissionRequired) && denied.homeDialer == nil)
let inactive = fresh(); inactive.appInForeground = false; inactive.considerVisionCableBootstrap()
inactive.appInForeground = true; inactive.considerVisionCableBootstrap()
check("backgrounded startup does not retry on activation", inactive.visionCableBootstrap.phase == .stopped(.foregroundRequired) && inactive.homeDialer == nil)
let inactiveScene = fresh(); inactiveScene.visionStartupForeground = false; inactiveScene.considerVisionCableBootstrap()
check("inactive foremost scene prevents enrollment", inactiveScene.homeDialer == nil)
let notStarted = fresh(); notStarted.visionStartupStarted = false; notStarted.appInForeground = false
notStarted.considerVisionCableBootstrap(); notStarted.stopVisionCableBootstrap(.foregroundRequired)
check("client lifecycle notifications before startup preserve waiting", notStarted.homeDialer == nil && notStarted.visionCableBootstrap.phase == .waiting(.waitingForService))
let keyless = fresh(); DeviceIdentity.available = false; keyless.considerVisionCableBootstrap()
check("locked key store does not pretend pairing", keyless.visionCableBootstrap.phase == .stopped(.keyUnavailable) && keyless.sentMethods.isEmpty)
DeviceIdentity.available = true
let pinned = fresh(); pinned.considerVisionCableBootstrap()
let target = pinned.homeDialer!.targets[0]
check("bootstrap dial forces actual IPv6-only cable target", pinned.homeDialer?.dials.first?.1 == true)
check("actual ask adapter forwards pin and removes Wi-Fi fallback", pinned.homeDialer?.pin == pin && target.fallback == nil && target.cableOnly && !target.peerToPeer)
pinned.homeDialer?.win(otherPin)
check("peer pin rejected before any PairRequest", pinned.sentMethods.isEmpty && pinned.savedMacs.isEmpty && pinned.visionCableBootstrap.phase == .stopped(.pinRejected))
let failedWire = fresh(); failedWire.considerVisionCableBootstrap(); let failedWireDialer = failedWire.homeDialer!
failedWireDialer.failCurrent()
check("actual HomeDialer failure has no Wi-Fi fallback or next target", failedWireDialer.dials.count == 1 && failedWire.homeDialer == nil && failedWire.visionCableBootstrap.phase == .stopped(.noAnswer))
let notCable = fresh(); notCable.cable = false; accept(notCable)
check("actual client cable check required before ask", notCable.sentMethods.isEmpty && notCable.visionCableBootstrap.phase == .stopped(.cableRejected))
check("bootstrap cannot use DEBUG cable override", notCable.allowedTestOverride == false)
let cancelled = fresh(); cancelled.considerVisionCableBootstrap(); let cancelledDialer = cancelled.homeDialer!
cancelled.stopVisionCableBootstrap(.cancelled); cancelledDialer.win(pin); cancelled.considerVisionCableBootstrap()
check("cancelled winner cannot ask or repeat", cancelled.sentMethods.isEmpty && cancelled.homeDialer == nil && cancelled.visionCableBootstrap.phase == .stopped(.cancelled))
let queued = fresh(); queued.queue.hold = true; accept(queued); queued.stopVisionCableBootstrap(.foregroundRequired); queued.queue.drain()
check("background revokes a queued unsent ask", queued.sentMethods.isEmpty && queued.savedMacs.isEmpty)
let late = fresh(); accept(late); late.stopVisionCableBootstrap(.foregroundRequired); late.pendingReply?(.answer(result, nil))
DispatchQueue.main.drain()
check("a late result after background never persists", late.savedMacs.isEmpty && late.sessionPins.isEmpty)
for reason in [PairResult.busy, PairResult.locked, PairResult.shown, PairResult.openOnMac, "unknown"] {
    let client = fresh(); client.reply = PairResult(ok: false, reason: reason, retryAfter: 0.2)
    let count = HomeDialer.instances.count
    accept(client); client.considerVisionCableBootstrap()
    check("host refusal never enters code UI or busy retry", client.savedMacs.isEmpty && client.homeAsk == nil && HomeDialer.instances.count == count + 1 && DispatchQueue.main.scheduled == 0)
}
for mutation in 0..<4 {
    var bad = result
    switch mutation {
    case 0: bad.macID = MacID.make(fingerprint: otherPin)
    case 1: bad.method = "code"
    case 2: bad.proof = "unexpected-proof"
    default: bad.recognitionKey = Base64URL.encode(Data(repeating: 1, count: 31))
    }
    let client = fresh(); client.reply = bad; accept(client)
    check("normal DiscoveryPolicy rejects malformed cable result", client.savedMacs.isEmpty && client.sessionPins.isEmpty)
}
let paired = fresh(); paired.reply = result; accept(paired)
check("accepted cable result uses actual normal save path", paired.savedMacs.count == 1 && paired.writes == 1 && paired.savedMacs[0].method == PairResult.cable && paired.savedMacs[0].homeTLS == true)
check("normal saved record retains original Bonjour instance", paired.savedMacs.first?.bonjourName?.utf8.elementsEqual(service.utf8) == true)
check("normal session starts pinned after pairing", paired.sessionPins == [pin] && paired.visionCableBootstrap.phase == .paired && !paired.connected)
check("normal preference is stored by pairing", UserDefaults.standard.string(forKey: StreamClient.preferredTrustedMacKey) == result.macID)
let countAfterPair = HomeDialer.instances.count
paired.considerVisionCableBootstrap(); paired.considerVisionCableBootstrap()
check("startup bootstrap never repeats", HomeDialer.instances.count == countAfterPair && paired.sentMethods == [PairRequest.ask] && paired.sentCable == [true])
let existing = fresh(); existing.savedMacs = paired.savedMacs; existing.considerVisionCableBootstrap()
check("saved pair refuses bootstrap before key creation", existing.homeDialer == nil && existing.identityCalls == 0 && existing.visionCableBootstrap.phase == .stopped(.savedPairExists))
let cold = fresh(.ordinary); cold.savedMacs = paired.savedMacs
cold.macs = [row(macID: result.macID, tagged: true)]; cold.armSavedMacAutoConnect()
check("actual saved automatic policy reconnects a cold process", cold.sessionPins == [pin] && cold.sentMethods.isEmpty && cold.identityCalls == 0)
cold.armSavedMacAutoConnect()
check("cold startup attempt is once per process", cold.sessionPins.count == 1)
for mutation in 0..<4 {
    let client = fresh(.ordinary); client.savedMacs = paired.savedMacs
    switch mutation {
    case 0: client.savedMacs[0].revoked = true
    case 1: client.savedMacs[0].newKey = true
    case 2: client.savedMacs[0].homeTLS = false
    default: UserDefaults.standard.set("stale-preference", forKey: StreamClient.preferredTrustedMacKey)
    }
    client.macs = [row(macID: result.macID, tagged: true)]; client.armSavedMacAutoConnect()
    check("invalid saved trust or stale preference never falls through", client.sessionPins.isEmpty && client.homeDialer == nil)
}
let ordinaryUnrelated = fresh(.ordinary); ordinaryUnrelated.savedMacs = paired.savedMacs
ordinaryUnrelated.macs = [row()]; ordinaryUnrelated.armSavedMacAutoConnect()
check("saved cold startup requires a recognized tagged network row", ordinaryUnrelated.sessionPins.isEmpty && ordinaryUnrelated.homeDialer == nil)
let normalAsk = fresh(.ordinary); normalAsk.ask(row(), savedID: nil, tagNamed: false)
check("existing nonbootstrap callers retain normal fallback", normalAsk.homeDialer?.pin == nil && normalAsk.homeDialer?.targets[0].fallback != nil && normalAsk.homeDialer?.targets[0].cableOnly == false)
func savedStartup(_ mode: Boot.Launch = .ordinary) -> StreamClient {
    let client = fresh(mode)
    client.macs = []
    client.savedMacs = paired.savedMacs
    client.savedMacs[0].addresses = [MacAddress(host: "fixture-mac.example.invalid", kind: MacAddress.vpn, via: "Fixture VPN")]
    UserDefaults.standard.set(client.savedMacs[0].macID, forKey: StreamClient.preferredTrustedMacKey)
    return client
}
func armRemote(_ client: StreamClient) -> DispatchWorkItem {
    let before = DispatchQueue.main.timers.count
    client.armSavedMacAutoConnect()
    precondition(DispatchQueue.main.timers.count == before + 1, "one startup deadline must be armed")
    return DispatchQueue.main.timers.last!.1
}
let away = savedStartup()
let awayTimer = armRemote(away)
check("no Bonjour cold start waits through discovery grace", away.remoteAttempts.isEmpty && away.sessionPins.isEmpty)
awayTimer.performEvenIfCancelled()
check("deadline hands the trusted saved ID to existing one-shot remote dial", away.remoteAttempts.count == 1 && away.remoteAttempts[0].0 == result.macID && away.remoteAttempts[0].1 == .launchArgument)
away.remoteDial = nil
awayTimer.performEvenIfCancelled(); away.discoveryChanged(); away.armSavedMacAutoConnect()
check("remote failure cannot rearm a cold-start attempt", away.remoteAttempts.count == 1 && away.identityCalls == 0 && away.sentMethods.isEmpty)
let duringGrace = savedStartup()
let cableTimer = armRemote(duringGrace)
duringGrace.macs = [row(macID: result.macID, tagged: true)]
duringGrace.discoveryChanged()
check("cable appearing during grace consumes startup with saved pin", duringGrace.sessionPins == [pin] && duringGrace.sessionRows.first?.wired != nil && cableTimer.cancelled)
cableTimer.performEvenIfCancelled()
check("late remote deadline cannot replace cable connection", duringGrace.remoteAttempts.isEmpty && duringGrace.sessionPins.count == 1)
let bothRows = savedStartup()
bothRows.macs = [row(wired: false, macID: result.macID, tagged: true), row(macID: result.macID, tagged: true)]
bothRows.armSavedMacAutoConnect()
check("actual cable wins over listed Wi-Fi before any remote grace", bothRows.sessionRows.first?.wired != nil && bothRows.remoteAttempts.isEmpty)
let wifiFirst = savedStartup()
wifiFirst.macs = [row(wired: false, macID: result.macID, tagged: true)]
wifiFirst.armSavedMacAutoConnect()
check("pinned network row starts immediately without remote attempt", wifiFirst.sessionRows.count == 1 && wifiFirst.remoteAttempts.isEmpty)
let manual = savedStartup()
let manualTimer = armRemote(manual)
manual.stopSavedMacAutoConnect()
let manualConnection = NWConnection()
manual.connection = manualConnection
manual.connected = true
manualTimer.performEvenIfCancelled()
check("already queued timer cannot replace manual session after cancellation", manual.connection === manualConnection && manual.remoteAttempts.isEmpty)
manual.connection = nil; manual.connected = false; manual.discoveryChanged(); manualTimer.performEvenIfCancelled()
check("manual session ending does not revive consumed startup", manual.remoteAttempts.isEmpty)
let changedPreference = savedStartup()
let preferenceTimer = armRemote(changedPreference)
var otherSaved = changedPreference.savedMacs[0]
otherSaved.fingerprint = Base64URL.encode(otherPin); otherSaved.macID = MacID.make(fingerprint: otherPin)
changedPreference.savedMacs.append(otherSaved)
changedPreference.rememberPreferredMac(otherSaved.macID)
preferenceTimer.performEvenIfCancelled()
check("new authenticated preference cancels old startup deadline", changedPreference.remoteAttempts.isEmpty && preferenceTimer.cancelled)
let rawPreference = savedStartup()
let rawPreferenceTimer = armRemote(rawPreference)
UserDefaults.standard.set("another-preference", forKey: StreamClient.preferredTrustedMacKey)
rawPreferenceTimer.performEvenIfCancelled()
check("deadline revalidates current preference even without discovery event", rawPreference.remoteAttempts.isEmpty)
for mutation in 0..<6 {
    let client = savedStartup()
    let timer = armRemote(client)
    switch mutation {
    case 0: client.savedMacs[0].revoked = true
    case 1: client.savedMacs[0].newKey = true
    case 2: client.savedMacs[0].homeTLS = false
    case 3: client.savedMacs[0].recognitionKey = Base64URL.encode(Data(repeating: 0x44, count: 32))
    case 4: client.savedMacs.removeAll()
    default: DeviceIdentity.available = false
    }
    timer.performEvenIfCancelled()
    DeviceIdentity.available = true
    client.discoveryChanged(); timer.performEvenIfCancelled()
    check("changed trust or unavailable device key stops deadline without enrollment or retry", client.remoteAttempts.isEmpty && client.sessionPins.isEmpty && client.identityCalls == 0 && client.sentMethods.isEmpty)
}
for occupied in 0..<8 {
    let client = savedStartup()
    let timer = armRemote(client)
    switch occupied {
    case 0: client.connected = true
    case 1: client.connection = NWConnection()
    case 2: client.reconnect = 1
    case 3: client.remoteDial = RemoteConnector()
    case 4: client.pairingDial = RemoteConnector()
    case 5: client.pairing = .working
    case 6: client.homeDialer = HomeDialer(targets: [], pin: nil, identity: RemoteIdentity(), queue: client.queue)
    default: client.homeAsk = HomeAsk(target: .init(endpoint: row().endpoint!, label: "fixture"), name: "fixture", cableRow: false, savedID: nil, tagNamed: false)
    }
    timer.performEvenIfCancelled()
    client.connected = false; client.connection = nil; client.reconnect = nil; client.remoteDial = nil
    client.pairingDial = nil; client.pairing = .idle; client.homeDialer = nil; client.homeAsk = nil
    timer.performEvenIfCancelled(); client.discoveryChanged()
    check("occupied startup does not replace work or revive when it finishes", client.remoteAttempts.isEmpty && client.sessionPins.isEmpty)
}
for appBackground in [false, true] {
    let client = savedStartup()
    let timer = armRemote(client)
    if appBackground { client.appInForeground = false } else { client.visionStartupForeground = false }
    timer.performEvenIfCancelled()
    client.appInForeground = true; client.visionStartupForeground = true
    timer.performEvenIfCancelled(); client.discoveryChanged()
    check("app or scene background permanently closes pending startup", client.remoteAttempts.isEmpty && timer.cancelled)
}
for mode in [launch, Boot.Launch.invalid] {
    let client = savedStartup(mode)
    let before = DispatchQueue.main.timers.count
    client.armSavedMacAutoConnect(); client.discoveryChanged()
    check("explicit or invalid cable bootstrap never arms remote fallback", client.remoteAttempts.isEmpty && DispatchQueue.main.timers.count == before)
}
let nameOnly = savedStartup()
nameOnly.macs = [row(macID: nil, tagged: false)]
let nameTimer = armRemote(nameOnly)
nameTimer.performEvenIfCancelled()
check("same-name unrecognized Bonjour row never enrolls or becomes a home dial", nameOnly.sessionPins.isEmpty && nameOnly.sentMethods.isEmpty && nameOnly.remoteAttempts.first?.0 == result.macID)
let missingAtLaunch = savedStartup()
DeviceIdentity.available = false
let missingTimers = DispatchQueue.main.timers.count
missingAtLaunch.armSavedMacAutoConnect()
DeviceIdentity.available = true; missingAtLaunch.discoveryChanged(); missingAtLaunch.armSavedMacAutoConnect()
check("missing launch key never rearms after unlock without a new process", missingAtLaunch.remoteAttempts.isEmpty && missingAtLaunch.sessionPins.isEmpty && DispatchQueue.main.timers.count == missingTimers)
let proofOnly = VisionAutoConnectStatus(build: "3", startupMode: .cableBootstrap, phase: .paired,
    savedMacCount: 1, expectedMacMatched: false, connected: false, catalogReceived: false,
    presentationReady: false, inputReady: false, reasonFixed: .waitingForService)
let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proofOnly)) as! [String: Any]
check("receipt schema has only allowlisted fields", Set(encoded.keys) == Set(["schema", "build", "startupMode", "phase", "savedMacCount", "expectedMacMatched", "connected", "catalogReceived", "presentationReady", "inputReady", "reasonFixed"]))
check("paired snapshot does not imply connection, presentation or input", encoded["connected"] as? Bool == false && encoded["presentationReady"] as? Bool == false && encoded["inputReady"] as? Bool == false)
let owner = FixtureAppOwner()
let concurrentOwner = FixtureAppOwner()
let concurrentWindow = UUID()
concurrentOwner.claim(concurrentWindow)
concurrentOwner.start(foreground: true)
let concurrentLease = concurrentOwner.windowLease!
let firstWindow = UUID(), otherWindow = UUID()
owner.claim(firstWindow)
owner.start(foreground: false)
check("initial inactive phase keeps actual app startup unarmed", owner.client.calls.isEmpty && owner.client.bootstrap.phase == .waiting(.waitingForService))
owner.release(firstWindow)
check("window release before first active preserves startup waiting", owner.client.bootstrap.phase == .waiting(.waitingForService) && owner.client.calls.isEmpty)
owner.claim(firstWindow); owner.claim(otherWindow)
let firstLease = owner.windowLease!
check("one window owns the app session", owner.windowOwner == firstWindow)
owner.start(foreground: true); owner.start(foreground: true)
check("initial inactive to active runs actual app startup once in order", owner.client.calls == ["startRemote", "armSavedMacAutoConnect", "startBrowsing"])
owner.release(otherWindow)
check("another window cannot revoke ownership", owner.windowOwner == firstWindow)
owner.release(firstWindow)
check("owner release closes foreground input admission", owner.windowOwner == nil && !owner.input.allowed && !owner.foreground)
check("closing one window preserves another window's live admission", concurrentOwner.owns(concurrentLease) && concurrentOwner.foreground)
check("concurrent window starts its own transport once", concurrentOwner.client.calls == ["startRemote", "armSavedMacAutoConnect", "startBrowsing"])
check("background after startup permanently cancels its pending bootstrap", owner.client.bootstrap.phase == .stopped(.foregroundRequired))
owner.claim(otherWindow)
check("new window rejects an old asynchronous owner's lease", !owner.owns(firstLease))
owner.release(otherWindow); owner.claim(firstWindow)
check("reclaiming the same window never revives an old callback", !owner.owns(firstLease) && owner.windowLease?.window == firstWindow)
var gestureEvents: [String] = []
let queuedOldTap = { firstLease.perform(current: owner.windowLease) { gestureEvents.append("old tap") } }
let queuedOldEnd = { firstLease.perform(current: owner.windowLease) { gestureEvents.append("old end") } }
queuedOldTap(); queuedOldEnd()
check("queued old tap and gesture end cannot reach a transferred session", gestureEvents.isEmpty)
owner.windowLease!.perform(current: owner.windowLease) { gestureEvents.append("current tap") }
check("current owner's input still reaches its session", gestureEvents == ["current tap"])
owner.setScenePhase(.inactive)
check("owner passes permission-sheet inactivity with its full lease", owner.client.microphoneScenes.last?.0 == owner.windowLease && owner.client.microphoneScenes.last?.1 == .inactive)
owner.setScenePhase(.active)
check("owner passes active admission without restarting startup", owner.client.microphoneScenes.last?.1 == .active && owner.client.calls == ["startRemote", "armSavedMacAutoConnect", "startBrowsing"])
owner.setScenePhase(.background)
check("owner distinguishes true scene background", owner.client.microphoneScenes.last?.1 == .background)
owner.release(firstWindow)
check("owner release passes nil microphone lease", owner.client.microphoneScenes.last?.0 == nil && owner.client.microphoneScenes.last?.1 == .background)
check("trusted requested row keeps reconnecting beyond twelve attempts", DiscoveryPolicy.redialRow(
    failed: 50, lastDialAt: 1000, foreground: true, now: 1030, lifetime: .whileRequested).dial)
check("trusted requested remote keeps reconnecting after two minutes", DiscoveryPolicy.remoteDialDue(
    listed: false, lostAt: 0, networkLeftAt: nil, rememberedDirect: false,
    pathChangedSinceLoss: false, now: 600, lifetime: .whileRequested).dial)
check("persistent reconnect still pauses in the background", !DiscoveryPolicy.redialRow(
    failed: 50, lastDialAt: 1000, foreground: false, now: 1030, lifetime: .whileRequested).dial)
check("persistent reconnect retains increasing retry spacing", DiscoveryPolicy.redialRow(
    failed: 50, lastDialAt: 1000, foreground: true, now: 1001, lifetime: .whileRequested).recheckAt == 1030)
check("legacy bounded retry behavior remains", !DiscoveryPolicy.redialRow(
    failed: 50, lastDialAt: 1000, foreground: true, now: 1030).dial)
print("RESULT_ASSERTIONS \(assertions) FAILURES \(failures)")
exit(failures == 0 ? 0 : 1)
