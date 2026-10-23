import Foundation

struct VisionRemoteAudioIntent {
    enum Direction: String, Codable, CaseIterable { case playback, microphone }
    struct Desire: Codable, Equatable {
        var playback = false
        var microphone = false
        subscript(_ direction: Direction) -> Bool {
            get { direction == .playback ? playback : microphone }
            set { if direction == .playback { playback = newValue } else { microphone = newValue } }
        }
    }
    struct Scope: Hashable {
        let connection: UUID
        let window: UUID
        let admission: UUID
        let video: UUID
        let foreground: UUID
        let privacy: UInt64
    }
    struct Context {
        var hostKey: String?
        var scope: Scope?
        var connected = false
        var authenticated = false
        var foreground = false
        var presented = false
        var inputBlocked = true
        var privacyVersion: Int?
        var protected = false
        var cleanupReady = false
        var playbackAvailable = false
        var microphoneAvailable = false
        var recordPermissionGranted = false
        var nativeBindingReady = false
        var admitted: Bool {
            hostKey != nil && scope != nil && connected && authenticated && foreground && presented &&
                !inputBlocked && privacyVersion == 2 && cleanupReady
        }
        var eligible: Bool { admitted && protected && nativeBindingReady }
    }
    struct Request: Equatable {
        let hostKey: String
        let scope: Scope
        let direction: Direction
        let revision: UInt64
    }
    private struct Attempt: Hashable {
        let scope: Scope
        let direction: Direction
    }
    private(set) var desires: [String: Desire]
    private(set) var revision: UInt64 = 0
    private var directionRevisions: [String: [Direction: UInt64]] = [:]
    private var connection: UUID?
    private var attempted: Set<Attempt> = []
    static let defaultsKey = "VisionRemoteAudioIntent.v1"

    init(desires: [String: Desire] = [:]) {
        self.desires = Dictionary(uniqueKeysWithValues: desires.keys.sorted().prefix(64).map { ($0, desires[$0]!) })
    }
    static func load(_ defaults: UserDefaults) -> Self {
        let data = defaults.data(forKey: defaultsKey) ?? Data()
        return Self(desires: (try? PropertyListDecoder().decode([String: Desire].self, from: data)) ?? [:])
    }
    func persist(_ defaults: UserDefaults) {
        if let data = try? PropertyListEncoder().encode(desires) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    func desired(_ direction: Direction, hostKey: String?) -> Bool {
        hostKey.flatMap { desires[$0]?[direction] } ?? false
    }
    mutating func setDesired(_ enabled: Bool, direction: Direction, hostKey: String) {
        revision &+= 1
        directionRevisions[hostKey, default: [:]][direction] = revision
        if desires[hostKey] == nil, desires.count >= 64, let evicted = desires.keys.sorted().first {
            desires.removeValue(forKey: evicted)
            directionRevisions.removeValue(forKey: evicted)
        }
        desires[hostKey, default: Desire()][direction] = enabled
    }
    func desiredRevision(_ direction: Direction, hostKey: String) -> UInt64 {
        directionRevisions[hostKey]?[direction] ?? 0
    }
    mutating func consume(_ direction: Direction, scope: Scope?) {
        if let scope {
            if connection != scope.connection { connection = scope.connection; attempted.removeAll() }
            attempted.insert(Attempt(scope: scope, direction: direction))
        }
    }
    mutating func requests(_ context: Context) -> [Request] {
        if let scope = context.scope, connection != scope.connection {
            connection = scope.connection
            attempted.removeAll()
        }
        guard context.eligible, let hostKey = context.hostKey, let scope = context.scope else { return [] }
        return Direction.allCases.compactMap { direction in
            guard desired(direction, hostKey: hostKey),
                  (direction == .playback ? context.playbackAvailable :
                    (context.microphoneAvailable && context.recordPermissionGranted)),
                  attempted.insert(Attempt(scope: scope, direction: direction)).inserted else { return nil }
            return Request(hostKey: hostKey, scope: scope, direction: direction, revision: desiredRevision(direction, hostKey: hostKey))
        }
    }
    func isCurrent(_ request: Request, context: Context) -> Bool {
        context.eligible && request.revision == desiredRevision(request.direction, hostKey: request.hostKey) && request.hostKey == context.hostKey &&
            request.scope == context.scope && desired(request.direction, hostKey: context.hostKey)
    }
}

#if os(visionOS)
import AVFoundation
import CryptoKit
import StreamProtocol

extension StreamClient {
    var visionAudioTrustedHostKey: String? {
        guard authenticatedVisionMacAudioPeer != nil, let id = session?.macID,
              let pin = savedMac(id)?.fingerprintData, MacID.make(fingerprint: pin) == id else { return nil }
        return SHA256.hash(data: pin).map { String(format: "%02x", $0) }.joined()
    }
    var visionAudioPrivacyMessage: String {
        if let problem = visionForwardingProblem { return problem }
        if visionAudioPrivacy?.version != 2 {
            return "Mac 음소거 보호를 지원하는 호스트로 업데이트하면 오디오를 사용할 수 있습니다."
        }
        if visionAudioPrivacy?.protected != true { return "Mac 음소거 보호를 확인하지 못해 오디오를 중지했습니다." }
        return "Mac은 음소거를 유지합니다. 허용한 오디오는 같은 저장된 Mac에 다시 연결할 때만 자동 재개합니다."
    }
    var visionPlaybackDesired: Bool { VisionRemoteAudioStore.shared.model.intent.desired(.playback, hostKey: visionAudioTrustedHostKey) }
    var visionMicrophoneDesired: Bool { VisionRemoteAudioStore.shared.model.intent.desired(.microphone, hostKey: visionAudioTrustedHostKey) }

    var visionAudioIntentContext: VisionRemoteAudioIntent.Context {
        var context = VisionRemoteAudioIntent.Context()
        if VisionReleaseTestContext.isTestBundle { return context }
        context.hostKey = visionAudioTrustedHostKey
        context.connected = connected && !visionWindowRetired
        context.authenticated = context.hostKey != nil
        context.foreground = visionStartupForeground && appInForeground && microphoneAdmission.active &&
            visionDisplaySelection.foreground
        context.inputBlocked = visionDisplaySelection.inputBlocked || visionAudioIntentModal || visionAudioIntentWithdrawing
        context.privacyVersion = visionAudioPrivacy?.version
        context.protected = visionAudioPrivacy?.protected == true && !visionAudioPrivacyBlocked
        context.cleanupReady = microphoneCleanupProblem == nil && visionAudio.cleanupProblem == nil &&
            VisionAudioSharedHardware.shared.cleanupProblem == nil
        context.playbackAvailable = visionAudio.presentation.canEnable
        context.microphoneAvailable = visionMicrophoneCanStart
        context.nativeBindingReady = visionForwarding?.binding != nil
        context.recordPermissionGranted = AVAudioApplication.shared.recordPermission == .granted
        if let lease = visionDisplaySelection.lease, lease == microphoneAdmission.lease,
           case .presented(let epoch) = visionInputBinding, active != .none {
            context.presented = true
            context.scope = .init(connection: visionAudioIntentConnection, window: lease.window,
                admission: lease.admission, video: epoch.id, foreground: visionAudioIntentForeground,
                privacy: visionAudioPrivacyRevision)
        }
        return context
    }

    @discardableResult
    func setVisionAudioDesired(_ enabled: Bool, direction: VisionRemoteAudioIntent.Direction,
                               expectedScope: VisionAudioScope? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return VisionRemoteAudioStore.shared.setDesired(enabled, client: self,
            direction: direction, expectedScope: expectedScope)
    }

    func observeVisionAudioPrivacy(_ list: WindowList) {
        if visionAudioIntentAwaitingSource == nil || visionAudioIntentAwaitingSource == list.active {
            visionAudioIntentWithdrawing = false
            visionAudioIntentAwaitingSource = nil
        }
        let wasProtected = visionAudioPrivacy?.version == 2 && visionAudioPrivacy?.protected == true
        visionAudioPrivacy = list.audioPrivacy
        if list.audioPrivacy?.version == 2, list.audioPrivacy?.protected == true {
            if !wasProtected { visionAudioPrivacyRevision &+= 1 }
            visionAudioPrivacyBlocked = false
        }
        if list.audioPrivacy?.protected == false ||
            (wasProtected && (list.audioPrivacy?.version != 2 || list.audioPrivacy?.protected != true)) {
            visionAudioPrivacyBlocked = true
            VisionRemoteAudioStore.shared.withdrawPrivacy(self)
        }
    }

    func reconcileVisionAudioIntent() {
        dispatchPrecondition(condition: .onQueue(.main))
        var context = visionAudioIntentContext
        let suspended = !context.connected || !context.foreground || context.inputBlocked ||
            !visionInputBinding.isConfirmed ||
            (visionAudioPrivacy?.version == 2 && !context.authenticated)
        if suspended {
            if !visionAudioIntentSuspended {
                visionAudioIntentSuspended = true
                visionAudioIntentForeground = UUID()
                visionAudioIntentNeedsMicrophoneCatalog = true
                VisionAudioSharedHardware.shared.revoke(owner: visionAudioOwnerID)
                visionAudio.stop()
                if microphonePolicy.phase != .authorizing || microphoneAdmission.scene != .inactive {
                    stopVisionMicrophoneActual()
                }
            }
            VisionRemoteAudioStore.shared.refresh()
            return
        }
        visionAudioIntentSuspended = false
        if visionAudioIntentNeedsMicrophoneCatalog, let list = visionAudioIntentCatalog,
           let peer = connection, case .presented(let epoch) = visionInputBinding,
           list.videoEpoch?.id == epoch.id {
            visionAudioIntentNeedsMicrophoneCatalog = false
            if microphonePolicy.scope == nil { microphoneObserve(list, from: peer) }
            context = visionAudioIntentContext
        }
        VisionRemoteAudioStore.shared.refresh()
    }
}
#endif
