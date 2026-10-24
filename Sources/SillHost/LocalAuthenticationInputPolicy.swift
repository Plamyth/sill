import Foundation
import CoreGraphics

struct LocalAuthenticationInputPolicy {
    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct Target: Equatable {
        let process: ProcessIdentity
        let window: CGWindowID
        let bounds: CGRect
    }

    struct Observation {
        let requestID: UUID
        let target: Target
        let expires: ContinuousClock.Instant
        let handoffTag: Int64
    }

    enum Stage { case session, annotated }
    struct Input {
        let type: CGEventType
        let flags: CGEventFlags
        let keyCode: Int64
        let point: CGPoint
        let sourcePID: Int64
        let sourceState: Int64
        let tag: Int64
        let targetPID: Int64
        let windowUnderPointer: Int64
        let windowHandlingPointer: Int64
    }

    private(set) var preparedRequestID: UUID?
    private(set) var observation: Observation?

    mutating func willBegin(_ requestID: UUID) {
        preparedRequestID = requestID
        observation = nil
    }

    mutating func revoke() { observation = nil }

    mutating func observe(_ target: Target?, challengeID: UUID?, now: ContinuousClock.Instant, tag: Int64) {
        guard let challengeID, challengeID == preparedRequestID, let target,
              target.process.pid > 0, target.process.startSeconds > 0, target.window > 0,
              target.bounds.origin.x.isFinite, target.bounds.origin.y.isFinite,
              target.bounds.width.isFinite, target.bounds.height.isFinite,
              target.bounds.width > 0, target.bounds.height > 0, (1...Int64(Int32.max)).contains(tag) else {
            revoke(); return
        }
        let sameTarget = observation?.requestID == challengeID && observation?.target == target &&
            observation.map { now < $0.expires } == true
        observation = Observation(requestID: challengeID, target: target,
            expires: now.advanced(by: .milliseconds(250)),
            handoffTag: sameTarget ? observation!.handoffTag : tag)
    }

    func current(challengeID: UUID?, now: ContinuousClock.Instant) -> Observation? {
        guard let challengeID, challengeID == preparedRequestID, let observation,
              observation.requestID == challengeID, now < observation.expires else { return nil }
        return observation
    }

    func allows(_ input: Input, stage: Stage, challengeID: UUID?, now: ContinuousClock.Instant,
                liveIdentity: ProcessIdentity?, receiverReady: Bool) -> Bool {
        guard receiverReady, let proof = current(challengeID: challengeID, now: now),
              liveIdentity == proof.target.process,
              input.sourcePID == 0, input.sourceState == CGEventSourceStateID.hidSystemState.rawValue,
              (stage == .session ? input.tag == 0 : input.tag == proof.handoffTag) else { return false }
        let allowedFlags: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad, .maskNonCoalesced]
        guard input.flags.rawValue & ~allowedFlags.rawValue == 0 else { return false }
        switch input.type {
        case .keyDown, .keyUp:
            // Text keys, editing keys and numeric keypad only. Function/media/global chords stay blocked.
            guard (0...51).contains(input.keyCode) || [53, 65, 67, 69, 71, 75, 76, 78, 81,
                82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 123, 124, 125, 126].contains(input.keyCode) else { return false }
        case .flagsChanged:
            guard [56, 57, 60].contains(input.keyCode) else { return false }
        case .leftMouseDown, .leftMouseUp:
            guard input.flags.rawValue & ~CGEventFlags.maskNonCoalesced.rawValue == 0,
                  input.point.x.isFinite, input.point.y.isFinite, proof.target.bounds.contains(input.point) else { return false }
            if stage == .annotated {
                guard input.windowUnderPointer == Int64(proof.target.window),
                      input.windowHandlingPointer == Int64(proof.target.window) else { return false }
            }
        default: return false
        }
        return stage == .session || input.targetPID == Int64(proof.target.process.pid)
    }
}
