import Foundation
import Security
import StreamProtocol
import os

let profileLookupFails = OSAllocatedUnfairLock(initialState: false)
func SecKeyCopyPublicKey(_ key: SecKey) -> SecKey? {
    if profileLookupFails.withLock({ $0 }) { return nil }
    return Security.SecKeyCopyPublicKey(key)
}

@MainActor final class RemoteAccess {
    var identity: HostIdentity?
    var remoteAccess = false
    let mobileEnrollmentDependencies: MobileEnrollmentDependencies
    var mobileEnrollmentRuntime: MobileEnrollmentHostRuntime?
    init(identity: HostIdentity?, dependencies: MobileEnrollmentDependencies) {
        self.identity = identity
        mobileEnrollmentDependencies = dependencies
    }
    func apply(_ enabled: Bool) {
        remoteAccess = enabled
        updateMobileEnrollment()
    }
    func mobileEnrollmentObservation(challenge: MobileEnrollment.ActiveChallenge,
                                     nowMS: Int64) throws -> MobileEnrollment.ActiveResultPayload {
        throw MobileEnrollmentRuntimeFailure.stopped
    }
    // PRODUCTION_METHODS
}
