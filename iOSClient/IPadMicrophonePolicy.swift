import Foundation
import StreamProtocol

/// Exact-peer microphone consent. Network and AVAudioEngine effects are returned to the owner;
/// observing a capability never requests permission or starts capture on its own.
struct IPadMicrophonePolicy {
    enum Phase: Equatable {
        case unavailable, off, requesting, capturing, live, stopping, failed(String)

        var canStop: Bool {
            switch self {
            case .requesting, .capturing, .live: true
            default: false
            }
        }
    }

    enum Effect: Equatable {
        case closeFrames
        case send(ObjectIdentifier, MicrophoneControl)
        case stopCapture
        case beginCapture(ObjectIdentifier, MicrophoneScope, UUID, UUID)
        case openFrames(ObjectIdentifier, MicrophoneScope, UUID)
    }

    private(set) var phase: Phase = .unavailable
    private(set) var peer: ObjectIdentifier?
    private(set) var scope: MicrophoneScope?
    private(set) var startRequestID: UUID?
    private(set) var grantID: UUID?
    private(set) var stopRequestID: UUID?
    private(set) var latestReceipt: MicrophoneReceipt?

    var canStart: Bool {
        guard scope != nil else { return false }
        if phase == .off { return true }
        if case .failed = phase { return stopRequestID == nil }
        return false
    }

    mutating func setConnection(_ next: ObjectIdentifier?) -> [Effect] {
        guard peer != next else { return [] }
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
        guard next != scope else { return [] }
        let effects = revoke()
        scope = next
        phase = next == nil ? .unavailable : .off
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
        phase = .requesting
        return [.send(peer, MicrophoneControl(operation: .start, requestID: id, scope: scope))]
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
            guard phase == .capturing || phase == .live || phase == .stopping else { return [] }
            phase = .stopping
            return [.closeFrames, .stopCapture]
        case .off:
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
        case .refused, .cleanupFailed:
            phase = .failed(String((state.reason ?? "Mac microphone unavailable").prefix(160)))
            if state.phase == .refused {
                startRequestID = nil
                stopRequestID = nil
            } else {
                stopRequestID = state.requestID
            }
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
        phase = .failed("Mac microphone did not answer.")
        // Lost start ACK: only the original start ID with nil grant may cancel it.
        stopRequestID = requestID
        return [.closeFrames,
                .send(origin, MicrophoneControl(operation: .stop, requestID: requestID,
                                               scope: scope)), .stopCapture]
    }

    mutating func stopTimedOut(_ requestID: UUID, from origin: ObjectIdentifier) -> [Effect] {
        guard peer == origin, phase == .stopping, stopRequestID == requestID else { return [] }
        phase = .failed("Mac microphone stop was not confirmed. Reconnect to recover.")
        return [.closeFrames, .stopCapture]
    }

    mutating func receive(_ receipt: MicrophoneReceipt, from origin: ObjectIdentifier) {
        guard peer == origin, phase == .live, scope == receipt.scope,
              grantID == receipt.grantID else { return }
        latestReceipt = receipt
    }

    mutating func sourceWillChange() -> [Effect] { revoke() }
    mutating func backgrounded() -> [Effect] { revoke() }

    private mutating func stopByUser() -> [Effect] {
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
        if phase.canStop, let peer, let scope, let startRequestID {
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
        phase = .unavailable
        scope = nil
        startRequestID = nil
        stopRequestID = nil
        grantID = nil
        latestReceipt = nil
        return effects
    }
}
