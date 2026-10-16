import Foundation
import Network

var checks = 0
func check(_ label: String, _ passes: @autoclosure () -> Bool) {
    checks += 1
    if !passes() { fatalError(label) }
}
func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
func kinds(_ peer: NWConnection) -> [StreamMessageKind] {
    peer.sent.map { StreamMessage.parseHeader(Data($0.prefix(StreamMessage.headerLength)))!.kind }
}
let input = AudioRouteEndpoint(uid: "fixture.input", name: "시험 입력", input: true, output: false)
let output = AudioRouteEndpoint(uid: "fixture.output", name: "시험 출력", input: false, output: true)
let other = AudioRouteEndpoint(uid: "fixture.usb", name: "시험 USB", input: false, output: true)
let initial = AudioRouteState(revision: UUID(), endpoints: [input, output, other],
    defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: output.uid), available: true)
let pin = Data([1, 2, 3])
let peer = NWConnection()
let client = StreamClient(peer: peer, pin: pin)
let lease = VisionWindowLease(window: UUID())
let routes = client.visionMacAudioRoutes
client.updateVisionMacAudioRoutes(lease: lease, foreground: true)
check("initial trusted foreground owner fetches once", kinds(peer) == [.fetchAudioRoutes])
client.updateVisionMacAudioRoutes(lease: lease, foreground: true)
check("same context never repeats initial fetch or selects", kinds(peer) == [.fetchAudioRoutes])
check("old host remains awaiting catalog", routes.model.state == nil && routes.draft == nil)
check("redacted status starts with zero selection requests", routes.status.selectionRequestCount == 0 && routes.status.outcome == .awaitingCatalog)
client.deliver(initial, from: peer); pump()
check("actual adapter admits current catalog", routes.draft != nil)
check("redacted status records received catalog without audio proof", routes.status.catalogAvailable && routes.status.catalogValid && routes.status.catalogCount == 3 && routes.status.currentInputKnown && routes.status.currentOutputKnown)
check("first chooser offer is once per controller", routes.takeOffer() && !routes.takeOffer())
var draft = routes.draft!
draft.outputUID = other.uid
check("hold enters before native change", client.link.hold(peer))
routes.apply(draft)
let pending = routes.model.pending!
check("native apply queues explicit request", pending.outputUID == other.uid && !kinds(peer).contains(.changeAudioRoute))
check("captured request status never means applied", routes.status.selectionRequestCount == 1 && routes.status.pending && routes.status.outcome == .waiting)
let replacementLease = VisionWindowLease(window: lease.window)
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
_ = client.link.unhold(peer); pump()
check("new admission cancels queued old-window change", !kinds(peer).contains(.changeAudioRoute))
check("same window UUID receives a new scope", routes.scope?.admission == replacementLease.admission && replacementLease.admission != lease.admission)
check("new window cannot reuse old catalog", routes.model.state == nil)
routes.apply(draft)
check("old-window draft cannot create pending", routes.model.pending == nil)
client.deliver(initial, from: peer)
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: false)
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
pump()
check("callback captured before background cannot seed resumed context", routes.model.state == nil)
client.deliver(initial, from: peer); pump()
var current = routes.draft!; current.outputUID = other.uid
check("timeout scenario enters hold", client.link.hold(peer))
routes.apply(current)
let timed = routes.model.pending!
NativeClock.now = 8
routes.expireIfNeeded()
_ = client.link.unhold(peer); pump()
check("native eight-second timeout cancels queued change", routes.model.pending == nil && !kinds(peer).contains(.changeAudioRoute))
let late = AudioRouteState(revision: UUID(), endpoints: initial.endpoints,
    defaults: AudioRouteDefaults(inputUID: input.uid, outputUID: other.uid), available: true,
    answering: timed.requestID, result: .applied)
client.deliver(late, from: peer); pump()
check("actual late adapter delivery cannot revive native timeout", routes.model.state == late && routes.model.outcome?.isSuccess == false)
let next = NWConnection()
client.replacePeer(next, pin: pin)
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
client.deliver(late, from: peer); pump()
check("old peer cannot populate replacement", routes.model.state == nil && routes.model.pending == nil)
check("replacement peer only fetched read-only", kinds(next) == [.fetchAudioRoutes])
RemoteTLS.pins[ObjectIdentifier(next)] = Data([9])
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
check("current TLS pin mismatch revokes native scope", routes.scope == nil)
RemoteTLS.pins[ObjectIdentifier(next)] = pin
client.macInfoSaved = false
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
check("unverified saved identity cannot bind", routes.scope == nil)
client.macInfoSaved = true
client.updateVisionMacAudioRoutes(lease: replacementLease, foreground: true)
client.deliver(initial, from: next); pump()
var closing = routes.draft!; closing.outputUID = other.uid
let closingScope = routes.scope!
check("chooser close scenario enters hold", client.link.hold(next))
routes.apply(closing)
let latestLease = VisionWindowLease(window: replacementLease.window)
client.updateVisionMacAudioRoutes(lease: latestLease, foreground: true)
client.deliver(initial, from: next); pump()
var latestDraft = routes.draft!; latestDraft.outputUID = other.uid
routes.apply(latestDraft)
let latestRequest = routes.model.pending!.requestID
routes.closeChooser(expectedScope: closingScope)
check("delayed old-window close preserves new held request", routes.model.pending?.requestID == latestRequest)
routes.closeChooser(expectedScope: nil)
check("unscoped close cannot cancel current held request", routes.model.pending?.requestID == latestRequest)
routes.closeChooser(expectedScope: routes.scope)
_ = client.link.unhold(next); pump()
check("closing chooser cancels native queued selection", routes.model.pending == nil && !kinds(next).contains(.changeAudioRoute))
client.revoke()
check("native revoke clears active context", routes.scope == nil)

let workspace = Workspace()
check("baseline native input admits", workspace.admits && workspace.input.allowed)
workspace.audioOfferShown = true
workspace.audioOfferScope = UUID()
workspace.open()
check("route sheet clears speaker confirmation", !workspace.audioOfferShown && workspace.audioOfferScope == nil)
check("actual modal input setter releases held input", !workspace.admits && !workspace.input.allowed && workspace.input.releases == 1)
let offerWorkspace = Workspace()
offerWorkspace.showOffer()
check("route first-offer also releases input", !offerWorkspace.admits && offerWorkspace.input.releases == 1)
let staleWorkspace = Workspace()
staleWorkspace.session.windowLease = VisionWindowLease(window: staleWorkspace.lease.window)
staleWorkspace.open()
check("revoked window action cannot open chooser", !staleWorkspace.macAudioShown)
check("pure native timeout constant remains eight", VisionMacAudioController.responseTimeout == 8)
let statusJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(routes.status)) as! [String: Any]
check("status schema contains only the redacted allowlist", Set(statusJSON.keys) == Set([
    "build", "trustedCurrentPeer", "owningWindow", "foreground", "catalogAvailable", "catalogValid", "catalogCount",
    "currentInputKnown", "currentOutputKnown", "pending", "outcome", "selectionRequestCount"]))
print("\(checks) Vision audio integration checks passed")
