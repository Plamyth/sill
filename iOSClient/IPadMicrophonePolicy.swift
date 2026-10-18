import Foundation
import StreamProtocol

/// Exact-peer microphone consent. Network and AVAudioEngine effects are returned to the owner;
/// observing a capability never requests permission or starts capture on its own.
struct IPadMicrophonePolicy {
    enum Phase: Equatable {
        case unavailable, off, authorizing, requesting, capturing, live, stopping, cleanupRequired, failed(String)

        var canStop: Bool {
            switch self {
            case .authorizing, .requesting, .capturing, .live: true
            default: false
            }
        }
    }

    enum Effect: Equatable {
        case requestPermission(ObjectIdentifier, MicrophoneScope, UUID)
        case closeFrames
        case send(ObjectIdentifier, MicrophoneControl)
        case stopCapture
        case beginCapture(ObjectIdentifier, MicrophoneScope, UUID, UUID)
        case openFrames(ObjectIdentifier, MicrophoneScope, UUID)
    }

    private(set) var hostCleanupRequired = false
    private(set) var phase: Phase = .unavailable
    private(set) var peer: ObjectIdentifier?
    private(set) var scope: MicrophoneScope?
    private(set) var startRequestID: UUID?
    private(set) var grantID: UUID?
    private(set) var stopRequestID: UUID?
    private(set) var latestReceipt: MicrophoneReceipt?

    var canStart: Bool {
        guard scope != nil, !hostCleanupRequired else { return false }
        if phase == .off { return true }
        if case .failed = phase { return stopRequestID == nil }
        return false
    }

    mutating func setConnection(_ next: ObjectIdentifier?) -> [Effect] {
        guard peer != next else { return [] }
        hostCleanupRequired = false
        let effects = revoke()
        peer = next
        return effects
    }

    mutating func observe(_ list: WindowList, from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin else { return [] }
        let next: MicrophoneScope?
        if let capability = list.microphone,
           let generation = list.inputGeneration.flatMap(UUID.init(uuidString:)),
           let epoch = list.videoEpoch,
           epoch.matches(source: list.active, generation: list.inputGeneration),
           list.active != .none {
            next = MicrophoneScope(peer: capability.peer, source: list.active,
                                   inputGeneration: generation, videoEpoch: epoch.id,
                                   destination: capability.destination,
                                   capability: capability.generation)
        } else { next = nil }
        let recovered = hostCleanupRequired && next != nil
        if recovered { hostCleanupRequired = false }
        guard next != scope || recovered else { return [] }
        let effects = revoke()
        scope = next
        phase = hostCleanupRequired ? .cleanupRequired : next == nil ? .unavailable : .off
        return effects
    }

    mutating func toggle() -> [Effect] {
        if phase.canStop { return stopByUser() }
        guard canStart, let peer, let scope else { return [] }
        let id = UUID()
        startRequestID = id
        stopRequestID = nil
        grantID = nil
        latestReceipt = nil
        phase = .authorizing
        return [.requestPermission(peer, scope, id)]
    }

    mutating func permissionResolved(_ allowed: Bool, requestID: UUID, scope expected: MicrophoneScope,
                                     from origin: ObjectIdentifier, microphoneAvailable: Bool = true) -> [Effect] {
        guard peer == origin, scope == expected, phase == .authorizing, startRequestID == requestID else { return [] }
        guard allowed && microphoneAvailable else {
            phase = .failed(microphoneAvailable ? "iPad 마이크 권한이 필요합니다." : "다른 기능에서 이미 마이크를 사용 중입니다.")
            startRequestID = nil
            return []
        }
        phase = .requesting
        return [.send(origin, MicrophoneControl(operation: .start, requestID: requestID, scope: expected))]
    }

    mutating func receive(_ state: MicrophoneState, from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin, scope == state.scope else { return [] }
        let matchesStart = state.requestID == startRequestID
        let matchesStop = state.requestID == stopRequestID
        guard matchesStart || matchesStop else { return [] }
        switch state.phase {
        case .preparing:
            return []
        case .active:
            guard matchesStart, phase == .requesting, let grant = state.grantID,
                  let peer, let scope else { return [] }
            grantID = grant
            phase = .capturing
            return [.beginCapture(peer, scope, state.requestID, grant)]
        case .retiring:
            guard phase == .requesting || phase == .capturing || phase == .live || phase == .stopping else { return [] }
            phase = .stopping
            return [.closeFrames, .stopCapture]
        case .off:
            hostCleanupRequired = false
            guard phase != .off && phase != .unavailable else { return [] }
            if let reason = state.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                phase = .failed(String(reason.prefix(160)))
            } else {
                phase = .off
            }
            startRequestID = nil
            stopRequestID = nil
            grantID = nil
            return [.closeFrames, .stopCapture]
        case .refused:
            phase = .failed(String((state.reason ?? "Mac 마이크를 사용할 수 없습니다.").prefix(160)))
            startRequestID = nil
            stopRequestID = nil
            grantID = nil
            return [.closeFrames, .stopCapture]
        case .cleanupFailed:
            hostCleanupRequired = true
            phase = .cleanupRequired
            stopRequestID = state.requestID
            grantID = nil
            return [.closeFrames, .stopCapture]
        }
    }

    mutating func captureStarted(requestID: UUID, grant: UUID,
                                 from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin, phase == .capturing, startRequestID == requestID,
              grantID == grant, let scope else { return [] }
        phase = .live
        return [.openFrames(origin, scope, grant)]
    }

    mutating func captureFailed(requestID: UUID, grant: UUID, from origin: ObjectIdentifier,
                                reason: String) -> [Effect] {
        guard peer == origin, (phase == .capturing || phase == .live), startRequestID == requestID,
              grantID == grant, let scope else { return [] }
        phase = .failed(String(reason.prefix(160)))
        let stop = MicrophoneControl(operation: .stop, requestID: UUID(), scope: scope, grantID: grant)
        stopRequestID = stop.requestID
        return [.closeFrames, .send(origin, stop), .stopCapture]
    }

    mutating func startTimedOut(_ requestID: UUID, from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin, phase == .requesting, startRequestID == requestID,
              let scope else { return [] }
        phase = .failed("Mac 마이크가 응답하지 않았습니다.")
        // Lost start ACK: only the original start ID with nil grant may cancel it.
        stopRequestID = requestID
        return [.closeFrames,
                .send(origin, MicrophoneControl(operation: .stop, requestID: requestID,
                                               scope: scope)), .stopCapture]
    }

    mutating func stopTimedOut(_ requestID: UUID, from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin, phase == .stopping, stopRequestID == requestID else { return [] }
        phase = .failed("Mac 마이크 중지가 확인되지 않았습니다. 다시 연결한 뒤 시도하세요.")
        return [.closeFrames, .stopCapture]
    }

    mutating func receive(_ receipt: MicrophoneReceipt, from origin: ObjectIdentifier) {
        guard peer == origin, phase == .live, scope == receipt.scope,
              grantID == receipt.grantID else { return }
        latestReceipt = receipt
    }

    mutating func sourceWillChange() -> [Effect] { revoke() }
    mutating func backgrounded() -> [Effect] {
        if phase.canStop { return stopByUser() }
        return [.closeFrames, .stopCapture]
    }
    mutating func inactive() -> [Effect] {
        if phase == .authorizing { return [] }
        return backgrounded()
    }
    mutating func interrupted() -> [Effect] { backgrounded() }

    private mutating func stopByUser() -> [Effect] {
        if phase == .authorizing {
            phase = .off
            startRequestID = nil
            return [.closeFrames, .stopCapture]
        }
        guard let peer, let scope, let startRequestID else { return [] }
        let control: MicrophoneControl
        if let grantID {
            let stopID = UUID()
            stopRequestID = stopID
            control = MicrophoneControl(operation: .stop, requestID: stopID,
                                        scope: scope, grantID: grantID)
        } else {
            stopRequestID = startRequestID
            control = MicrophoneControl(operation: .stop, requestID: startRequestID,
                                        scope: scope)
        }
        phase = .stopping
        return [.closeFrames, .send(peer, control), .stopCapture]
    }

    private mutating func revoke() -> [Effect] {
        let effects: [Effect]
        if phase.canStop, phase != .authorizing, let peer, let scope, let startRequestID {
            let stop: MicrophoneControl
            if let grantID {
                stop = MicrophoneControl(operation: .stop, requestID: UUID(),
                                         scope: scope, grantID: grantID)
            } else {
                stop = MicrophoneControl(operation: .stop, requestID: startRequestID,
                                         scope: scope)
            }
            effects = [.closeFrames, .send(peer, stop), .stopCapture]
        } else { effects = [.closeFrames, .stopCapture] }
        phase = hostCleanupRequired ? .cleanupRequired : .unavailable
        scope = nil
        startRequestID = nil
        stopRequestID = nil
        grantID = nil
        latestReceipt = nil
        return effects
    }
}
