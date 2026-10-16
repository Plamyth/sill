import Foundation

let firstPlayer = UUID()
let secondPlayer = UUID()
let firstMicrophone = UUID()
let secondMicrophone = UUID()
let uplinkMicrophone = UUID()
var state = IPadAudioLeaseState()

try state.acquire(.remotePlayback,leaseId:firstPlayer)
try state.acquire(.remotePlayback,leaseId:secondPlayer)
try state.acquire(.remotePlayback,leaseId:secondPlayer)
precondition(state.leases.count == 2 && !state.needsMicrophone)

precondition(state.release(leaseId:firstPlayer))
precondition(state.leases[secondPlayer] == .remotePlayback && !state.isEmpty)
try state.acquire(.canvasDictation,leaseId:firstMicrophone)
precondition(state.needsMicrophone && state.leases.count == 2)

do {
    try state.acquire(.microphoneUplink,leaseId:uplinkMicrophone)
    fatalError("Uplink opened while canvas dictation owns the microphone")
} catch IPadAudioLeaseState.LeaseError.microphoneInUse {}

do {
    try state.acquire(.canvasDictation,leaseId:secondMicrophone)
    fatalError("A second microphone acquired the session")
} catch IPadAudioLeaseState.LeaseError.microphoneInUse {}

do {
    try state.acquire(.canvasDictation,leaseId:secondPlayer)
    fatalError("A playback lease changed roles")
} catch IPadAudioLeaseState.LeaseError.roleMismatch {}

precondition(state.release(leaseId:secondPlayer))
precondition(state.needsMicrophone && !state.isEmpty)
precondition(state.release(leaseId:firstMicrophone))
try state.acquire(.microphoneUplink,leaseId:uplinkMicrophone)
precondition(state.needsMicrophone && state.leases[secondPlayer] == nil)
try state.acquire(.remotePlayback,leaseId:secondPlayer)
precondition(state.leases[secondPlayer] == .remotePlayback && state.needsMicrophone)
do {
    try state.acquire(.canvasDictation,leaseId:firstMicrophone)
    fatalError("Canvas dictation opened while uplink owns the microphone")
} catch IPadAudioLeaseState.LeaseError.microphoneInUse {}
precondition(state.release(leaseId:uplinkMicrophone))
precondition(!state.needsMicrophone && !state.isEmpty)
precondition(state.release(leaseId:secondPlayer))
precondition(state.isEmpty)
precondition(!state.release(leaseId:firstPlayer))

print("iPad audio lease: two players retain output; dictation and uplink exclude each other; final release closes session")
