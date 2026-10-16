import Foundation

enum DriverFailure: Error { case rejected }
let first = UUID()
let second = UUID()
var coordinator = IPadAudioLeaseCoordinator()

do {
    try coordinator.acquire(.microphoneUplink, id: first) { _, _ in throw DriverFailure.rejected }
    fatalError("Expected failed activation")
} catch DriverFailure.rejected {}
precondition(coordinator.holds(first) && coordinator.recoveryOwner == first)
do {
    try coordinator.acquire(.canvasDictation, id: second) { _, _ in }
    fatalError("A second microphone entered during failed cleanup")
} catch IPadAudioLeaseCoordinator.Error.cleanupRequired {}
do {
    try coordinator.release(id: first) { _, _ in throw DriverFailure.rejected }
    fatalError("Expected failed restoration")
} catch DriverFailure.rejected {}
precondition(coordinator.holds(first) && coordinator.recoveryOwner == first)
try coordinator.release(id: first) { old, next in
    precondition(old.needsMicrophone && next.isEmpty)
}
precondition(!coordinator.holds(first) && coordinator.recoveryOwner == nil)
try coordinator.acquire(.canvasDictation, id: second) { old, next in
    precondition(old.isEmpty && next.needsMicrophone)
}
do {
    try coordinator.release(id: second) { _, _ in throw DriverFailure.rejected }
    fatalError("Expected failed deactivation")
} catch DriverFailure.rejected {}
precondition(coordinator.holds(second) && coordinator.recoveryOwner == second)
try coordinator.release(id: second) { _, next in precondition(next.isEmpty) }
precondition(coordinator.leases.isEmpty)
print("iPad audio cleanup owner survives activation and release failures")
