import Foundation
import StreamProtocol

final class Peer {}
let firstObject = Peer()
let otherObject = Peer()
let firstPeer = ObjectIdentifier(firstObject)
let otherPeer = ObjectIdentifier(otherObject)
let generation = UUID()
let epoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
                       geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
let capability = MicrophoneCapability(peer: UUID(), destination: UUID(), generation: UUID())
let listed = WindowList(macName: "Mac", windows: [], active: .desktop,
                        inputGeneration: generation.uuidString, videoEpoch: epoch,
                        microphone: capability)
let oldHost = WindowList(macName: "Mac", windows: [], active: .desktop,
                         inputGeneration: generation.uuidString, videoEpoch: epoch)

func control(_ effects: [IPadMicrophonePolicy.Effect]) -> MicrophoneControl? {
    for effect in effects {
        if case .send(_, let value) = effect { return value }
    }
    return nil
}

func start(_ policy: inout IPadMicrophonePolicy) -> MicrophoneControl {
    let effects = policy.toggle()
    guard case .requestPermission(let peer, let scope, let id) = effects.first else { fatalError("Permission must precede host start") }
    precondition(control(effects) == nil && policy.phase == .authorizing)
    return control(policy.permissionResolved(true, requestID: id, scope: scope, from: peer))!
}

var policy = IPadMicrophonePolicy()
_ = policy.setConnection(firstPeer)
_ = policy.observe(oldHost, from: firstPeer)
precondition(policy.phase == .unavailable && policy.toggle().isEmpty)
_ = policy.observe(listed, from: firstPeer)
precondition(policy.phase == .off && policy.scope != nil)
let scope = policy.scope!
let firstStart = start(&policy)
precondition(firstStart.operation == .start && firstStart.grantID == nil)
precondition(policy.phase == .requesting)

let grant = UUID()
let answer = MicrophoneState(requestID: firstStart.requestID, scope: scope,
                             phase: .active, grantID: grant)
precondition(policy.receive(answer, from: otherPeer).isEmpty)
precondition(policy.phase == .requesting)
let cancel = control(policy.toggle())!
precondition(cancel.operation == .stop && cancel.requestID == firstStart.requestID && cancel.grantID == nil)
precondition(policy.receive(answer, from: firstPeer).isEmpty)
precondition(policy.phase == .stopping)
precondition(policy.stopTimedOut(UUID(), from: firstPeer).isEmpty)
_ = policy.receive(MicrophoneState(requestID: firstStart.requestID, scope: scope,
                                   phase: .off, grantID: nil), from: firstPeer)
precondition(policy.phase == .off)

let refusedStart = start(&policy)
let refusedReason = "Mac input renderer could not start"
_ = policy.receive(MicrophoneState(requestID: refusedStart.requestID, scope: scope,
                                   phase: .off, grantID: nil, reason: refusedReason), from: firstPeer)
precondition(policy.phase == .failed(refusedReason))
precondition(policy.canStart)

let secondStart = start(&policy)
precondition(secondStart.requestID != firstStart.requestID)
let secondAnswer = MicrophoneState(requestID: secondStart.requestID, scope: scope,
                                   phase: .active, grantID: grant)
let begun = policy.receive(secondAnswer, from: firstPeer)
precondition(begun == [.beginCapture(firstPeer, scope, secondStart.requestID, grant)])
precondition(policy.phase == .capturing)
precondition(policy.captureStarted(requestID: firstStart.requestID, grant: grant,
                                   from: firstPeer).isEmpty)
precondition(policy.phase == .capturing)
let opened = policy.captureStarted(requestID: secondStart.requestID, grant: grant,
                                   from: firstPeer, now: 100)
precondition(opened == [.openFrames(firstPeer, scope, grant)] && policy.phase == .live)
precondition(policy.takeReceiptRequest(now: 105)?.operation == .receipt)
let receipt = MicrophoneReceipt(scope: scope, grantID: grant, admittedPackets: 2,
                                renderedFrames: 960, applicationQueueAgeMilliseconds: 3)
policy.receive(MicrophoneReceipt(scope: scope, grantID: UUID(), admittedPackets: 50,
                                 renderedFrames: 50_000, applicationQueueAgeMilliseconds: 1),
               from: firstPeer)
precondition(policy.latestReceipt == nil)
policy.receive(receipt, from: firstPeer)
precondition(policy.latestReceipt == receipt)

let revoked = policy.sourceWillChange()
let revokeStop = control(revoked)!
precondition(revoked.first == .closeFrames && revoked.last == .stopCapture)
precondition(revokeStop.operation == .stop && revokeStop.grantID == grant)
precondition(policy.phase == .unavailable && policy.scope == nil)
precondition(policy.receive(secondAnswer, from: firstPeer).isEmpty)

_ = policy.observe(listed, from: firstPeer)
let thirdStart = start(&policy)
let timeoutStop = control(policy.startTimedOut(thirdStart.requestID, from: firstPeer))!
precondition(timeoutStop.requestID == thirdStart.requestID && timeoutStop.grantID == nil)
precondition(policy.phase == .failed("Mac 마이크가 응답하지 않았습니다."))
precondition(!policy.canStart && policy.toggle().isEmpty)
precondition(policy.receive(MicrophoneState(requestID: thirdStart.requestID, scope: scope,
                                            phase: .active, grantID: UUID()), from: firstPeer).isEmpty)
_ = policy.receive(MicrophoneState(requestID: thirdStart.requestID, scope: scope,
                                   phase: .off, grantID: nil), from: firstPeer)
precondition(policy.phase == .off)

let fourthStart = start(&policy)
let fourthGrant = UUID()
_ = policy.receive(MicrophoneState(requestID: fourthStart.requestID, scope: scope,
                                   phase: .active, grantID: fourthGrant), from: firstPeer)
_ = policy.captureStarted(requestID: fourthStart.requestID, grant: fourthGrant, from: firstPeer)
let fourthStop = control(policy.toggle())!
precondition(policy.phase == .stopping)
_ = policy.stopTimedOut(fourthStop.requestID, from: firstPeer)
precondition(!policy.canStart && policy.phase == .failed("Mac 마이크 중지가 확인되지 않았습니다. 다시 연결한 뒤 시도하세요."))
_ = policy.receive(MicrophoneState(requestID: fourthStop.requestID, scope: scope,
                                   phase: .off, grantID: nil), from: firstPeer)
precondition(policy.canStart && policy.phase == .off)

_ = policy.setConnection(otherPeer)
precondition(policy.phase == .unavailable && policy.toggle().isEmpty)
precondition(policy.observe(listed, from: firstPeer).isEmpty)
_ = policy.observe(listed, from: otherPeer)
precondition(policy.phase == .off)
let invalidEpoch = WindowList(macName: "Mac", windows: [], active: .desktop,
                              inputGeneration: UUID().uuidString, videoEpoch: epoch,
                              microphone: capability)
_ = policy.observe(invalidEpoch, from: otherPeer)
precondition(policy.phase == .unavailable && policy.toggle().isEmpty)
print("iPad microphone owner and cancellation policy passed")

var consent = IPadMicrophonePolicy()
_ = consent.setConnection(firstPeer)
_ = consent.observe(listed, from: firstPeer)
let permission = consent.toggle()
guard case .requestPermission(let consentPeer, let consentScope, let consentID) = permission.first else { fatalError("missing consent") }
precondition(control(permission) == nil)
precondition(consent.inactive().isEmpty && consent.phase == .authorizing)
precondition(consent.startTimedOut(consentID, from: consentPeer).isEmpty)
_ = consent.backgrounded()
precondition(consent.phase == .off && consent.scope == consentScope)
precondition(consent.permissionResolved(true, requestID: consentID, scope: consentScope, from: consentPeer).isEmpty)
let stalePermission = consent.toggle()
guard case .requestPermission(_, _, let staleID) = stalePermission.first else { fatalError("missing second consent") }
_ = consent.setConnection(otherPeer)
precondition(consent.permissionResolved(true, requestID: staleID, scope: consentScope, from: consentPeer).isEmpty)
_ = consent.observe(listed, from: otherPeer)
let busyPermission = consent.toggle()
guard case .requestPermission(let busyPeer, let busyScope, let busyID) = busyPermission.first else { fatalError("missing third consent") }
precondition(consent.permissionResolved(true, requestID: busyID, scope: busyScope, from: busyPeer, microphoneAvailable: false).isEmpty)
precondition(consent.canStart)
let interruptedStart = start(&consent)
let interruptedScope = consent.scope!
let interruptedGrant = UUID()
_ = consent.receive(MicrophoneState(requestID: interruptedStart.requestID, scope: interruptedScope, phase: .active, grantID: interruptedGrant), from: otherPeer)
_ = consent.captureStarted(requestID: interruptedStart.requestID, grant: interruptedGrant, from: otherPeer)
precondition(consent.observe(listed, from: otherPeer).isEmpty && consent.phase == .live)
let interruptionStop = control(consent.interrupted())!
precondition(consent.scope == interruptedScope && consent.phase == .stopping)
_ = consent.receive(MicrophoneState(requestID: interruptionStop.requestID, scope: interruptedScope, phase: .off, grantID: interruptedGrant), from: otherPeer)
precondition(consent.phase == .off && consent.canStart)
precondition(consent.interrupted() == [.closeFrames, .stopCapture] && consent.canStart)
let failedStop = start(&consent)
_ = consent.receive(MicrophoneState(requestID: failedStop.requestID, scope: interruptedScope, phase: .cleanupFailed, grantID: interruptedGrant), from: otherPeer)
precondition(consent.phase == .cleanupRequired && !consent.canStart && consent.toggle().isEmpty)
_ = consent.observe(oldHost, from: otherPeer)
precondition(consent.hostCleanupRequired && consent.phase == .cleanupRequired && consent.scope == nil)
precondition(consent.toggle().isEmpty)
_ = consent.observe(oldHost, from: otherPeer)
precondition(consent.phase == .cleanupRequired)
_ = consent.observe(listed, from: otherPeer)
precondition(consent.phase == .off && consent.canStart && !consent.hostCleanupRequired && consent.grantID == nil)
print("Permission precedes host start; cleanup guidance survives nil catalog until fresh capability; recovery requires opt-in")

func liveMicrophone(now: Double = 100) -> (IPadMicrophonePolicy, MicrophoneControl, UUID) {
    var value = IPadMicrophonePolicy()
    _ = value.setConnection(firstPeer)
    _ = value.observe(listed, from: firstPeer)
    let request = start(&value)
    let grant = UUID()
    _ = value.receive(MicrophoneState(requestID: request.requestID, scope: request.scope,
                                     phase: .active, grantID: grant), from: firstPeer)
    _ = value.captureStarted(requestID: request.requestID, grant: grant, from: firstPeer, now: now)
    return (value, request, grant)
}

func microphoneReceipt(scope: MicrophoneScope, grant: UUID, queueAge: Double = 3,
                       frames: UInt64 = 960) -> MicrophoneReceipt {
    MicrophoneReceipt(scope: scope, grantID: grant, admittedPackets: 2,
                      renderedFrames: frames, applicationQueueAgeMilliseconds: queueAge)
}

var (timed, timedStart, timedGrant) = liveMicrophone()
let timedReceipt = microphoneReceipt(scope: timedStart.scope, grant: timedGrant)
precondition(timed.currentReceipt == nil)
precondition(!timed.receive(timedReceipt, from: firstPeer), "Unsolicited receipt must be rejected")
precondition(timed.currentReceipt == nil)
precondition(timed.takeReceiptRequest(now: 104.999) == nil, "4.999 seconds is too early")
let timedRequest = timed.takeReceiptRequest(now: 105)!
precondition(timedRequest.operation == .receipt && timedRequest.scope == timedStart.scope && timedRequest.grantID == timedGrant)
precondition(timed.currentReceipt == nil, "Requesting a receipt is not receiving one")
precondition(timed.takeReceiptRequest(now: 106) == nil, "Only one request per live grant")
precondition(timed.receive(timedReceipt, from: firstPeer))
precondition(timed.currentReceipt == timedReceipt)
precondition(!timed.receive(timedReceipt, from: firstPeer), "Identical duplicate must be rejected")
precondition(!timed.receive(microphoneReceipt(scope: timedStart.scope, grant: timedGrant, frames: 1_920), from: firstPeer))
precondition(timed.currentReceipt == timedReceipt, "Duplicate response must not replace accepted receipt")
precondition(timed.takeReceiptRequest(now: 110) == nil)

var (validated, validatedStart, validatedGrant) = liveMicrophone()
precondition(validated.takeReceiptRequest(now: 105) != nil)
let validReceipt = microphoneReceipt(scope: validatedStart.scope, grant: validatedGrant)
precondition(!validated.receive(validReceipt, from: otherPeer))
precondition(!validated.receive(microphoneReceipt(scope: validatedStart.scope, grant: UUID()), from: firstPeer))
let expectedScope = validatedStart.scope
let wrongScopes = [
    MicrophoneScope(peer: UUID(), source: expectedScope.source, inputGeneration: expectedScope.inputGeneration,
                    videoEpoch: expectedScope.videoEpoch, destination: expectedScope.destination, capability: expectedScope.capability),
    MicrophoneScope(peer: expectedScope.peer, source: .window(7), inputGeneration: expectedScope.inputGeneration,
                    videoEpoch: expectedScope.videoEpoch, destination: expectedScope.destination, capability: expectedScope.capability),
    MicrophoneScope(peer: expectedScope.peer, source: expectedScope.source, inputGeneration: UUID(),
                    videoEpoch: expectedScope.videoEpoch, destination: expectedScope.destination, capability: expectedScope.capability),
    MicrophoneScope(peer: expectedScope.peer, source: expectedScope.source, inputGeneration: expectedScope.inputGeneration,
                    videoEpoch: UUID(), destination: expectedScope.destination, capability: expectedScope.capability),
    MicrophoneScope(peer: expectedScope.peer, source: expectedScope.source, inputGeneration: expectedScope.inputGeneration,
                    videoEpoch: expectedScope.videoEpoch, destination: UUID(), capability: expectedScope.capability),
    MicrophoneScope(peer: expectedScope.peer, source: expectedScope.source, inputGeneration: expectedScope.inputGeneration,
                    videoEpoch: expectedScope.videoEpoch, destination: expectedScope.destination, capability: UUID())
]
for wrongScope in wrongScopes {
    precondition(!validated.receive(microphoneReceipt(scope: wrongScope, grant: validatedGrant), from: firstPeer))
    precondition(validated.currentReceipt == nil)
}
for badAge in [-1, Double.nan, Double.infinity, -Double.infinity] {
    precondition(!validated.receive(microphoneReceipt(scope: expectedScope, grant: validatedGrant, queueAge: badAge), from: firstPeer))
    precondition(validated.currentReceipt == nil)
}
let zeroAgeReceipt = microphoneReceipt(scope: expectedScope, grant: validatedGrant, queueAge: 0)
precondition(validated.receive(zeroAgeReceipt, from: firstPeer), "Rejected replies must not consume the pending request")
precondition(validated.currentReceipt == zeroAgeReceipt)

for invalidNow in [Double.nan, Double.infinity, -Double.infinity, 99] {
    var (clock, _, _) = liveMicrophone()
    precondition(clock.takeReceiptRequest(now: invalidNow) == nil)
    precondition(clock.currentReceipt == nil)
}
for invalidStart in [Double.nan, Double.infinity, -Double.infinity] {
    var (clock, _, _) = liveMicrophone(now: invalidStart)
    precondition(clock.takeReceiptRequest(now: 105) == nil, "Invalid capture time must not authorize a receipt")
}

var (duplicateActive, duplicateStart, duplicateGrant) = liveMicrophone()
let duplicateAnswer = MicrophoneState(requestID: duplicateStart.requestID, scope: duplicateStart.scope,
                                      phase: .active, grantID: duplicateGrant)
precondition(duplicateActive.receive(duplicateAnswer, from: firstPeer).isEmpty)
precondition(duplicateActive.captureStarted(requestID: duplicateStart.requestID, grant: duplicateGrant,
                                            from: firstPeer, now: 104).isEmpty)
precondition(duplicateActive.takeReceiptRequest(now: 104.999) == nil)
precondition(duplicateActive.takeReceiptRequest(now: 105) != nil, "Duplicate active must not restart the five-second interval")
precondition(duplicateActive.receive(duplicateAnswer, from: firstPeer).isEmpty)
precondition(duplicateActive.takeReceiptRequest(now: 110) == nil, "Duplicate active must not permit a second request")

var (off, offStart, offGrant) = liveMicrophone()
precondition(off.takeReceiptRequest(now: 105) != nil)
let lateOffReceipt = microphoneReceipt(scope: offStart.scope, grant: offGrant)
let offControl = control(off.toggle())!
precondition(off.phase == .stopping && off.currentReceipt == nil)
precondition(!off.receive(lateOffReceipt, from: firstPeer))
precondition(off.takeReceiptRequest(now: 106) == nil)
_ = off.receive(MicrophoneState(requestID: offControl.requestID, scope: offStart.scope,
                                phase: .off, grantID: offGrant), from: firstPeer)
precondition(off.phase == .off && off.currentReceipt == nil)
precondition(!off.receive(lateOffReceipt, from: firstPeer))
precondition(off.takeReceiptRequest(now: 200) == nil)
_ = timed.toggle()
precondition(timed.currentReceipt == nil, "Accepted receipt must disappear immediately on OFF")

var (reconnected, oldStart, oldGrant) = liveMicrophone()
precondition(reconnected.takeReceiptRequest(now: 105) != nil)
let oldReceipt = microphoneReceipt(scope: oldStart.scope, grant: oldGrant)
_ = reconnected.setConnection(nil)
precondition(reconnected.currentReceipt == nil && reconnected.takeReceiptRequest(now: 106) == nil)
precondition(!reconnected.receive(oldReceipt, from: firstPeer))
_ = reconnected.setConnection(firstPeer)
_ = reconnected.observe(listed, from: firstPeer)
let newStart = start(&reconnected)
let newGrant = UUID()
_ = reconnected.receive(MicrophoneState(requestID: newStart.requestID, scope: newStart.scope,
                                        phase: .active, grantID: newGrant), from: firstPeer)
precondition(reconnected.takeReceiptRequest(now: 210) == nil, "Host active without local capture is not live")
_ = reconnected.captureStarted(requestID: newStart.requestID, grant: newGrant, from: firstPeer, now: 200)
precondition(!reconnected.receive(oldReceipt, from: firstPeer))
precondition(reconnected.takeReceiptRequest(now: 204.999) == nil)
precondition(reconnected.takeReceiptRequest(now: 205)?.grantID == newGrant)
precondition(!reconnected.receive(oldReceipt, from: firstPeer), "Previous connection receipt must not satisfy a new grant")
let newReceipt = microphoneReceipt(scope: newStart.scope, grant: newGrant)
precondition(reconnected.receive(newReceipt, from: firstPeer))
precondition(reconnected.currentReceipt == newReceipt)
_ = reconnected.setConnection(otherPeer)
precondition(reconnected.currentReceipt == nil)
precondition(!reconnected.receive(newReceipt, from: firstPeer))

var (changedSource, sourceStart, sourceGrant) = liveMicrophone()
precondition(changedSource.takeReceiptRequest(now: 105) != nil)
let sourceReceipt = microphoneReceipt(scope: sourceStart.scope, grant: sourceGrant)
precondition(changedSource.receive(sourceReceipt, from: firstPeer))
_ = changedSource.sourceWillChange()
precondition(changedSource.currentReceipt == nil && changedSource.takeReceiptRequest(now: 106) == nil)
precondition(!changedSource.receive(sourceReceipt, from: firstPeer))
let windowEpoch = VideoEpoch(generation: generation.uuidString, source: .window(7),
                              geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
let windowList = WindowList(macName: "Mac", windows: [], active: .window(7),
                             inputGeneration: generation.uuidString, videoEpoch: windowEpoch, microphone: capability)
_ = changedSource.observe(windowList, from: firstPeer)
let windowStart = start(&changedSource)
precondition(windowStart.scope != sourceStart.scope)
let windowGrant = UUID()
_ = changedSource.receive(MicrophoneState(requestID: windowStart.requestID, scope: windowStart.scope,
                                          phase: .active, grantID: windowGrant), from: firstPeer)
_ = changedSource.captureStarted(requestID: windowStart.requestID, grant: windowGrant, from: firstPeer, now: 300)
precondition(changedSource.takeReceiptRequest(now: 304.999) == nil)
precondition(changedSource.takeReceiptRequest(now: 305)?.scope == windowStart.scope)
precondition(!changedSource.receive(sourceReceipt, from: firstPeer))
precondition(!changedSource.receive(microphoneReceipt(scope: sourceStart.scope, grant: windowGrant), from: firstPeer))
let windowReceipt = microphoneReceipt(scope: windowStart.scope, grant: windowGrant)
precondition(changedSource.receive(windowReceipt, from: firstPeer))
precondition(changedSource.currentReceipt == windowReceipt)
print("Microphone receipt timing, validation, duplicate suppression and lifecycle isolation passed")
