var checked = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) { checked += 1; if !condition() { fatalError("FAIL: \(name)") }; print("PASS: \(name)") }
let linkLocal: [UInt8] = [0xfe,0x80] + Array(repeating:0,count:13) + [1]
let scope = DiscoveryPolicy.Interface(name: "en2", type: .wiredEthernet)
func allowed(_ bytes: [UInt8], reply: UInt32 = 9, zone: UInt32 = 9, kind: DiscoveryPolicy.Interface.Kind = .wiredEthernet, own: [(interface:String,address:[UInt8])] = StreamClient.own) -> Bool {
 OwnerWiredPolicy.addressAllowed(bytes, replyIndex: reply, scopeIndex: zone, interfaceIndex: 9, interface: .init(name:"en2",type:kind), own:own)
}
check("IPv6 NCM peer accepted", allowed(linkLocal))
check("DNS scope zero bound to queried interface", allowed(linkLocal, zone:0))
check("different reply interface rejected", !allowed(linkLocal, reply:10))
check("different sockaddr scope rejected", !allowed(linkLocal, zone:10))
check("Wi-Fi rejected", !allowed(linkLocal, kind:.wifi))
check("IPv4 link-local peer rejected", !allowed([169,254,1,9]))
check("global IPv6 rejected", !allowed([0x20,1] + Array(repeating:0,count:14)))
check("ULA peer rejected", !allowed([0xfd,1] + Array(repeating:0,count:14)))
check("LAN on same wired interface rejected", !allowed(linkLocal, own:StreamClient.own + [("en2",[192,168,1,2])] ))
check("own address rejected", !allowed(StreamClient.own[0].address))
check("no interface addresses rejected", !allowed(linkLocal,own:[]))
check("link-local on other interface is insufficient", !allowed(linkLocal,own:[("en3",linkLocal)]))
var budget = OwnerWiredPolicy.Budget()
check("first attempt admitted", budget.begin("listing",now:0))
check("immediate retry refused", !budget.begin("listing",now:0.1))
check("retry uses existing backoff", budget.next("listing",now:0.1) == DiscoveryPolicy.upWait(failures:1))
check("second attempt after backoff", budget.begin("listing",now:100))
check("same listing cannot retry forever", !budget.begin("listing",now:10000))
budget.keep([]); check("new discovery generation can retry",budget.begin("listing",now:10001))
func fresh(connected: Bool = false) -> StreamClient {
 OwnerWiredResolver.pending = []; DeviceIdentity.available = true; UIDevice.current.userInterfaceIdiom = .pad
 interfaces = ["en2":9]; StreamClient.own = [("en2",[0xfe,0x80]+Array(repeating:0,count:13)+[2])]
 let client = StreamClient(); client.connected = connected; if connected { client.connection = NWConnection() }; return client
}
do { let c = fresh(); check("registered startup begins cable discovery",c.beginOwnerWired("owner",why:.automatic)); OwnerWiredResolver.answer(0,success:true); check("saved remotePort used, not Bonjour port",c.usb == 1 && c.lastPort == 7469 && c.tailnet == 0) }
do { let c = fresh(); c.records = []; check("empty store cannot USB bootstrap",!c.beginOwnerWired("owner",why:.automatic)); check("empty store creates no identity or resolver", OwnerWiredResolver.pending.isEmpty) }
do { let c = fresh(); DeviceIdentity.available = false; check("missing existing mTLS identity denied",!c.beginOwnerWired("owner",why:.automatic)) }
do { let c = fresh(); c.records[0].revoked = true; check("revoked registration denied",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); c.records[0].newKey = true; check("newKey registration denied",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); c.records[0].remotePort = 65536; check("invalid stored port rejected",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); c.records[0].fingerprintData = Data(repeating:8,count:32); check("Mac ID and pin mismatch rejected",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); c.records[0].method = "legacy"; check("legacy cable not intercepted",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); UIDevice.current.userInterfaceIdiom = .phone; check("owner USB feature is iPad only",!c.beginOwnerWired("owner",why:.tap)) }
do { let c = fresh(); _ = c.beginOwnerWired("owner",why:.automatic); OwnerWiredResolver.answer(0,success:false); check("failed resolution falls back once to Tailnet",c.tailnet == 1 && c.usb == 0) }
do { let c = fresh(); _ = c.beginOwnerWired("owner",why:.automatic); c.macs=[]; OwnerWiredResolver.answer(0,success:true); check("unplug during resolve falls back without USB",c.tailnet == 1 && c.usb == 0) }
do { let c = fresh(); _ = c.beginOwnerWired("owner",why:.automatic); c.cancelOwnerWiredResolution(); OwnerWiredResolver.answer(0,success:true); check("cancelled late callback cannot dial or fallback",c.tailnet == 0 && c.usb == 0) }
do { let c = fresh(); _ = c.beginOwnerWired("owner",why:.automatic); c.connection=NWConnection(); OwnerWiredResolver.answer(0,success:true); check("another peer adopted before DNS reply is preserved",c.tailnet == 0 && c.usb == 0) }
do { let c = fresh(); _ = c.beginOwnerWired("owner",why:.automatic); c.records[0].fingerprintData=Data(repeating:8,count:32); OwnerWiredResolver.answer(0,success:true); check("pin changes invalidate late DNS callback",c.tailnet == 0 && c.usb == 0) }
func staged() -> (StreamClient,NWConnection,NWConnection) { let c=fresh(connected:true); let old=c.connection!; _=c.beginOwnerWired("owner",why:.automatic); OwnerWiredResolver.answer(0,success:true); return (c,old,c.moving!.connection) }
do { let(c,old,candidate)=staged(); check("TLS ready alone preserves old session and audio",c.connection === old && old.cancels == 0 && candidate.state == .ready && c.committed == 0 && c.audioRebind == 0); c.homeListProbed(candidate,kept:[],host:"launch"); check("catalog alone waits for signed MacInfo",c.probes == 1 && c.connection === old && c.committed == 0); c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:true)); check("verified catalog commits via existing handover entry",c.committed == 1 && c.connection === candidate) }
do { let(c,old,candidate)=staged(); c.moveProbed(candidate,kept:[],host:"wrong-launch",macInfo:.init(valid:true)); check("other Mac or launch cannot replace old connection",c.connection === old && c.committed == 0 && c.audioRebind == 0) }
do { let(c,old,candidate)=staged(); c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:false)); check("unverified catalog cannot replace healthy Tailnet",c.connection === old && c.committed == 0 && c.audioRebind == 0) }
do { let(c,old,candidate)=staged(); candidate.fingerprint=Data(repeating:8,count:32); c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:true)); check("wrong TLS pin rejected before audio rebinding",c.connection === old && c.audioRebind == 0 && c.committed == 0) }
do { let(c,old,candidate)=staged(); interfaces=["en2":10]; c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:true)); check("interface index reuse invalidates candidate",c.connection === old && c.committed == 0) }
do { let(c,old,candidate)=staged(); c.moving=nil; c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:true)); check("late catalog after move cancellation preserves old",c.connection === old && c.committed == 0) }
do { let(c,old,candidate)=staged(); candidate.cancel(); c.moveProbed(candidate,kept:[],host:"launch",macInfo:.init(valid:true)); check("failed candidate cannot hand over after late catalog",c.connection === old && c.committed == 0) }
do { let(c,old,candidate)=staged(); c.installActualMoveHandler(candidate); candidate.stateUpdateHandler?(.ready); check("actual ready callback probes without disconnecting old", c.probes == 1 && c.connection === old && c.committed == 0 && c.audioRebind == 0); candidate.stateUpdateHandler?(.ready); check("late repeated ready cannot commit", c.connection === old && c.committed == 0) }
do { let(c,old,candidate)=staged(); c.installActualMoveHandler(candidate); c.moveSaidGoodbye(candidate,Goodbye(reason:"owner-wired-unsupported")); candidate.stateUpdateHandler?(.failed("Host 242 not installed")); check("Host unsupported rejection preserves healthy Tailnet and audio", c.connection === old && old.cancels == 0 && c.committed == 0 && c.audioRebind == 0) }
do { let(c,old,candidate)=staged(); c.ownerWiredSession = c.moving?.ownerWired; c.moving=nil; interfaces=[:]; c.ownerWiredChanged(); check("unplugged active USB closes only its peer for remote recovery", old.cancels == 1 && candidate.cancels == 0) }
print("owner-wired: \(checked) checks passed")
