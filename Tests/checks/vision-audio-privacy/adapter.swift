import Foundation

struct VisionAudioScope: Equatable { let id = UUID() }
final class InertHardware {
    var isIdle = true
    var holdCleanup = false
    var revoked: [UUID] = []
    func revoke(owner: UUID) { revoked.append(owner) }
}
enum VisionAudioSharedHardware { static let shared = InertHardware() }
final class InertPlayback {
    var starts = 0, stops = 0
    func enable(expectedScope: VisionAudioScope?) -> Bool {
        starts += 1
        VisionAudioSharedHardware.shared.isIdle = false
        return true
    }
    func stop() {
        stops += 1
        if !VisionAudioSharedHardware.shared.holdCleanup { VisionAudioSharedHardware.shared.isIdle = true }
    }
}
final class StreamClient {
    let visionAudioOwnerID = UUID()
    let visionAudio = InertPlayback()
    var context: VisionRemoteAudioIntent.Context
    var microphoneAuthorization: UUID?
    var visionAudioPrivacyBlocked = false
    var microphoneStarts = 0, microphoneStops = 0
    var visionAudioTrustedHostKey: String? { context.hostKey }
    var visionAudioIntentContext: VisionRemoteAudioIntent.Context {
        var result = context
        if visionAudioPrivacyBlocked { result.protected = false }
        return result
    }
    init(_ key: String) {
        context = .init()
        context.hostKey = key
        context.scope = .init(connection: UUID(), window: UUID(), admission: UUID(), video: UUID(), foreground: UUID(), privacy: 1)
        context.connected = true; context.authenticated = true; context.foreground = true
        context.presented = true; context.inputBlocked = false; context.privacyVersion = 1
        context.protected = true; context.cleanupReady = true; context.playbackAvailable = true
        context.microphoneAvailable = true; context.recordPermissionGranted = true
    }
    func stopVisionMicrophoneActual() { microphoneStops += 1 }
    func toggleVisionMicrophone() { microphoneStarts += 1 }
    func startVisionMicrophoneAutomatically() { microphoneStarts += 1 }
}
