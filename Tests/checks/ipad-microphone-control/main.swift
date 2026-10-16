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

var policy = IPadMicrophonePolicy()
_ = policy.setConnection(firstPeer)
_ = policy.observe(oldHost, from: firstPeer)
precondition(policy.phase == .unavailable && policy.toggle().isEmpty)
_ = policy.observe(listed, from: firstPeer)
precondition(policy.phase == .off && policy.scope != nil)
let scope = policy.scope!
let firstStart = control(policy.toggle())!
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

let refusedStart = control(policy.toggle())!
let refusedReason = "Mac input renderer could not start"
_ = policy.receive(MicrophoneState(requestID: refusedStart.requestID, scope: scope,
                                   phase: .off, grantID: nil, reason: refusedReason), from: firstPeer)
precondition(policy.phase == .failed(refusedReason))
precondition(policy.canStart)

let secondStart = control(policy.toggle())!
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
                                   from: firstPeer)
precondition(opened == [.openFrames(firstPeer, scope, grant)] && policy.phase == .live)
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
let thirdStart = control(policy.toggle())!
let timeoutStop = control(policy.startTimedOut(thirdStart.requestID, from: firstPeer))!
precondition(timeoutStop.requestID == thirdStart.requestID && timeoutStop.grantID == nil)
precondition(policy.phase == .failed("Mac microphone did not answer."))
precondition(!policy.canStart && policy.toggle().isEmpty)
precondition(policy.receive(MicrophoneState(requestID: thirdStart.requestID, scope: scope,
                                            phase: .active, grantID: UUID()), from: firstPeer).isEmpty)
_ = policy.receive(MicrophoneState(requestID: thirdStart.requestID, scope: scope,
                                   phase: .off, grantID: nil), from: firstPeer)
precondition(policy.phase == .off)

let fourthStart = control(policy.toggle())!
let fourthGrant = UUID()
_ = policy.receive(MicrophoneState(requestID: fourthStart.requestID, scope: scope,
                                   phase: .active, grantID: fourthGrant), from: firstPeer)
_ = policy.captureStarted(requestID: fourthStart.requestID, grant: fourthGrant, from: firstPeer)
let fourthStop = control(policy.toggle())!
precondition(policy.phase == .stopping)
_ = policy.stopTimedOut(fourthStop.requestID, from: firstPeer)
precondition(!policy.canStart && policy.phase == .failed("Mac microphone stop was not confirmed. Reconnect to recover."))
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
