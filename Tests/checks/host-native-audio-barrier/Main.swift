import Foundation

struct LocalAudioParticipantFacts {
    let admissionFenced, startsSettled, mediaDetached, callbacksDrained, buffersEmpty, workersExited: Bool
    var quiescent: Bool { admissionFenced && startsSettled && mediaDetached && callbacksDrained && buffersEmpty && workersExited }
}
@MainActor final class Privacy {
    final class Registry { var isFenced = true }
    let participants = Registry()
    var isReturningLocal = false
}
@MainActor final class Receiver {
    var retirementComplete = true
    var revocations = 0
    func forgetCapabilities() {}
    func revoke(reason: String) { revocations += 1 }
    func waitForRetirement() async -> Bool { retirementComplete }
}
@MainActor final class Ingress {
    var localReturnDetached = false
    func revoke() { localReturnDetached = true }
}
@MainActor final class Capture {
    var retirementConfirmed = true
    var hasStream = false
}
@MainActor final class Lifecycle { var isIdle = true }
@MainActor final class Server {
    final class Sentry {
        var localReturnFenced = false
        func fenceForLocalReturn() { localReturnFenced = true }
    }
    let sentryAdmission = Sentry()
    var drainResult = true
    var drains = 0
    func drainRemoteAudio(completion: (Bool) -> Void) { drains += 1; completion(drainResult) }
}
@MainActor final class Host {
    var audioPrivacy: Privacy? = Privacy()
    let microphoneReceiver = Receiver(), microphoneIngress = Ingress()
    let server = Server(), remoteAudioCapture = Capture(), remoteAudioLifecycle = Lifecycle()
    var physicalAudioRoutesRetired = false, localAudioReturnDrained = true, remoteAudioRunning = true
    var remoteAudioSubscribers: Set<Int> = [1]
    var remoteAudioRequests: [Int: Int] = [1: 1], remoteAudioActions: [Int: Int] = [1: 1]
    var afterRevoke: (() -> Void)?
    func revokeRemoteAudio(reason: String) async {
        remoteAudioSubscribers.removeAll(); remoteAudioRequests.removeAll(); remoteAudioActions.removeAll()
        remoteAudioRunning = false
        afterRevoke?()
    }
    // PRODUCTION_METHODS
}
@main struct Checks {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        let forwarding = Host()
        let prepared = await forwarding.prepareLocalAudioReturn()
        check(prepared && forwarding.localAudioReturnFacts().quiescent)
        check(!forwarding.server.sentryAdmission.localReturnFenced)
        check(forwarding.physicalAudioRoutesRetired && forwarding.microphoneReceiver.revocations == 1)
        let returning = Host(); returning.audioPrivacy!.isReturningLocal = true
        let returned = await returning.prepareLocalAudioReturn()
        check(returned && returning.server.sentryAdmission.localReturnFenced)
        for scenario in 0..<6 {
            let failed = Host()
            switch scenario {
            case 0: failed.microphoneReceiver.retirementComplete = false
            case 1: failed.server.drainResult = false
            case 2: failed.audioPrivacy!.participants.isFenced = false
            case 3: failed.remoteAudioCapture.retirementConfirmed = false
            case 4: failed.remoteAudioCapture.hasStream = true
            default: failed.remoteAudioLifecycle.isIdle = false
            }
            let result = await failed.prepareLocalAudioReturn()
            check(!result && !failed.localAudioReturnFacts().quiescent)
            check(!failed.server.sentryAdmission.localReturnFenced && failed.physicalAudioRoutesRetired)
        }
        let late = Host()
        late.afterRevoke = { late.remoteAudioRequests[9] = 9 }
        let lateResult = await late.prepareLocalAudioReturn()
        check(!lateResult && !late.localAudioReturnFacts().quiescent)
        print("PASS \(count) actual native barrier checks; HAL, media and device operations are inert")
    }
}
