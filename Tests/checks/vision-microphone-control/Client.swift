import AVFoundation
import Foundation
import Network
import os
import StreamProtocol

final class ClientGraph: VisionAudioGraphDriving {
    var recordPermissionGranted = true
    var input: VisionAudioCaptureGraph?
    func configure(_ profile: VisionAudioProfile) throws {}
    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws {
        input = capture
        capture?.formatChanged(AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1)!)
    }
    func stop() throws {}
    func deactivate() throws {}
}
enum VisionAudioSharedHardware {
    static let graph = ClientGraph()
    static let shared = VisionAudioHardware(driver:graph)
}
let permissionRequests = OSAllocatedUnfairLock(initialState:0)
func testPermission() async -> Bool { true }
final class StreamClient {
    var connection: NWConnection?
    let visionAudioOwnerID = UUID()
    var microphonePhase: IPadMicrophonePolicy.Phase = .unavailable
    var microphoneCleanupProblem: String?
    var microphoneReceipt: MicrophoneReceipt?
    var microphonePolicy = IPadMicrophonePolicy()
    let microphoneFrames = IPadMicrophoneFrameGate()
    var microphoneCapture: VisionMicrophoneCapture?
    var microphoneCaptureToken: UUID?
    var microphoneAdmission = VisionMicrophoneAdmission(lease: VisionWindowLease(window: UUID()),
        scene: .active, applicationActive: true)
    var microphoneAuthorization: VisionMicrophoneAuthorization?
    var requestVisionMicrophonePermission: (@escaping (Bool) -> Void) -> Void = { completion in
        permissionRequests.withLock { $0 += 1 }
        completion(true)
    }
    func connectionLost(_ c: NWConnection, error: NWError) {}
}
