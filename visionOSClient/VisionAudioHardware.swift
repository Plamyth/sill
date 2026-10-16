import AVFoundation
import Foundation
import os

enum VisionAudioRole: Hashable { case playback, capture }

struct VisionAudioClaim: Equatable {
    let owner: UUID
    let role: VisionAudioRole
    let epoch: UUID
}

enum VisionAudioProfile: Equatable { case playback, microphone }

struct VisionAudioPlaybackGraph {
    let format: VisionAudioFormat
    let render: AVAudioSourceNodeRenderBlock
}

struct VisionAudioCaptureGraph {
    let formatChanged: (AVAudioFormat) -> Void
    // The tap buffer is borrowed. The consumer must synchronously copy it and fence queued output.
    let copyInput: (AVAudioPCMBuffer, AVAudioTime) -> Void
}

protocol VisionAudioGraphDriving: AnyObject {
    var recordPermissionGranted: Bool { get }
    func configure(_ profile: VisionAudioProfile) throws
    func start(playback: VisionAudioPlaybackGraph?, capture: VisionAudioCaptureGraph?) throws
    func stop() throws
    func deactivate() throws
}

// Native graph operations run on main. Reservation and revocation also run from decode/network callers.
final class VisionAudioHardware: @unchecked Sendable {
    private struct Claims {
        var lease = VisionAudioLease()
        var reserved: [VisionAudioRole: VisionAudioClaim] = [:]
        var revoked: Set<VisionAudioRole> = []
        var committed: [VisionAudioRole: VisionAudioClaim] = [:]
        var generation: UUID?
        var problem: String?
    }
    private struct Playback {
        let claim: VisionAudioClaim
        let version: UInt64
        let graph: VisionAudioPlaybackGraph
        let authorization: () -> VisionAudioPlaybackAuthorization
    }
    private struct Capture {
        let claim: VisionAudioClaim
        let graph: VisionAudioCaptureGraph
        let permitted: () -> Bool
        let stopped: (String) -> Void
    }

    private let claims = OSAllocatedUnfairLock(initialState: Claims())
    private let driver: VisionAudioGraphDriving
    private var playback: Playback?
    private var capture: Capture?
    private var hardwareTouched = false
    private var transitioning = false
    private var problemHandlers: [UUID: (String?) -> Void] = [:]

    init(driver: VisionAudioGraphDriving) { self.driver = driver }

    func reserve(owner: UUID, role: VisionAudioRole, epoch: UUID) -> VisionAudioClaim? {
        claims.withLock { state in
            guard state.problem == nil, state.reserved[role] == nil,
                  state.lease.owner == nil || state.lease.owner == owner else { return nil }
            if state.lease.owner == nil, !state.lease.acquire(owner) { return nil }
            let claim = VisionAudioClaim(owner: owner, role: role, epoch: epoch)
            state.reserved[role] = claim
            return claim
        }
    }

    func revoke(_ claim: VisionAudioClaim) {
        claims.withLock { state in
            guard state.reserved[claim.role] == claim else { return }
            state.revoked.insert(claim.role)
            state.committed.removeValue(forKey: claim.role)
        }
    }

    func cleanupProblem(owner: UUID) -> String? {
        claims.withLock { $0.lease.owner == owner ? $0.problem : nil }
    }

    var cleanupProblem: String? { claims.withLock { $0.problem } }

    // An explicit cleanup can recover a quarantined resource after its original window has closed.
    func retryCleanup() {
        guard let owner = claims.withLock({ $0.problem == nil ? nil : $0.lease.owner }) else { return }
        _ = retryCleanup(owner: owner)
    }

    func observeProblems(owner: UUID, handler: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        problemHandlers[owner] = handler
        handler(cleanupProblem)
    }

    func removeObserver(owner: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        problemHandlers.removeValue(forKey: owner)
    }

    func matches(_ claim: VisionAudioClaim, version: UInt64) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return playback?.claim == claim && playback?.version == version && isCommitted(claim)
    }

    func startPlayback(_ claim: VisionAudioClaim, format: VisionAudioFormat, version: UInt64,
                       authorization: @escaping () -> VisionAudioPlaybackAuthorization, render: @escaping AVAudioSourceNodeRenderBlock) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !transitioning, claim.role == .playback, isReserved(claim), authorization() == .current else { throw CancellationError() }
        playback = Playback(claim: claim, version: version,
                            graph: VisionAudioPlaybackGraph(format: format, render: render), authorization: authorization)
        try rebuild()
    }

    // This does not request permission, negotiate a grant, convert PCM, or send a packet.
    func beginCapture(owner: UUID, epoch: UUID, permitted: @escaping () -> Bool,
                      formatChanged: @escaping (AVAudioFormat) -> Void,
                      copyInput: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
                      stopped: @escaping (String) -> Void) throws -> VisionAudioClaim {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !transitioning, permitted(), driver.recordPermissionGranted,
              let claim = reserve(owner: owner, role: .capture, epoch: epoch) else { throw CancellationError() }
        capture = Capture(claim: claim,
                          graph: VisionAudioCaptureGraph(formatChanged: formatChanged, copyInput: copyInput),
                          permitted: permitted, stopped: stopped)
        try rebuild()
        return claim
    }

    func close(_ claim: VisionAudioClaim) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard claims.withLock({ $0.reserved[claim.role] == claim }) else { return nil }
        revoke(claim)
        if let problem = cleanupProblem(owner: claim.owner) { return problem }
        guard !transitioning else {
            quarantine("Audio authorization changed during a graph transition.")
            return cleanupProblem(owner: claim.owner)
        }
        if playback?.claim == claim { playback = nil }
        if capture?.claim == claim { capture = nil }
        do {
            try rebuild()
            claims.withLock { state in
                guard state.reserved[claim.role] == claim else { return }
                state.reserved.removeValue(forKey: claim.role)
                state.revoked.remove(claim.role)
                if state.reserved.isEmpty { _ = state.lease.release(claim.owner) }
            }
            return nil
        } catch { return cleanupProblem(owner: claim.owner) ?? error.localizedDescription }
    }

    func retryCleanup(owner: UUID) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !transitioning else { return cleanupProblem(owner: owner) }
        guard claims.withLock({ $0.lease.owner == owner && $0.problem != nil }) else { return nil }
        transitioning = true
        defer { transitioning = false }
        do {
            try driver.stop()
            if hardwareTouched { try driver.deactivate() }
            hardwareTouched = false
            playback = nil
            capture = nil
            claims.withLock { state in
                state.reserved.removeAll()
                state.revoked.removeAll()
                state.committed.removeAll()
                state.generation = nil
                state.problem = nil
                _ = state.lease.release(owner)
            }
            Array(problemHandlers.values).forEach { $0(nil) }
            return nil
        } catch {
            quarantine(error.localizedDescription)
            return cleanupProblem(owner: owner)
        }
    }

    func invalidate(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard claims.withLock({ $0.lease.owner != nil }) else { return }
        quarantine(reason)
        guard !transitioning else { return }
        do { try driver.stop() }
        catch { quarantine(reason + " Stop failed: " + error.localizedDescription) }
    }

    private func isReserved(_ claim: VisionAudioClaim) -> Bool {
        claims.withLock { $0.problem == nil && $0.reserved[claim.role] == claim && !$0.revoked.contains(claim.role) }
    }

    private func isCommitted(_ claim: VisionAudioClaim, generation: UUID? = nil) -> Bool {
        claims.withLockIfAvailable { state in
            state.problem == nil && state.committed[claim.role] == claim && !state.revoked.contains(claim.role)
                && state.generation != nil && (generation == nil || state.generation == generation)
        } ?? false
    }

    private func rebuild() throws {
        precondition(!transitioning)
        transitioning = true
        defer { transitioning = false }
        claims.withLock { $0.generation = nil; $0.committed.removeAll() }
        do {
            try driver.stop()
            guard playback != nil || capture != nil else {
                if hardwareTouched { try driver.deactivate() }
                hardwareTouched = false
                return
            }
            try validateRoles()
            hardwareTouched = true // Category and activation calls can mutate before throwing.
            try driver.configure(capture == nil ? .playback : .microphone)
            try validateRoles()
            let generation = UUID()
            let output = playback.map { spec in
                VisionAudioPlaybackGraph(format: spec.graph.format) { [weak self] flag, time, frames, list in
                    for buffer in UnsafeMutableAudioBufferListPointer(list) {
                        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                    }
                    guard self?.isCommitted(spec.claim, generation: generation) == true else { return noErr }
                    return spec.graph.render(flag, time, frames, list)
                }
            }
            let input = capture.map { spec in
                VisionAudioCaptureGraph(formatChanged: spec.graph.formatChanged) { [weak self] buffer, time in
                    guard buffer.frameLength > 0, buffer.frameLength <= 16_384,
                          self?.isCommitted(spec.claim, generation: generation) == true else { return }
                    spec.graph.copyInput(buffer, time)
                }
            }
            try driver.start(playback: output, capture: input)
            try validateRoles()
            let committed = claims.withLock { state -> Bool in
                guard state.problem == nil,
                      playback.map({ state.reserved[.playback] == $0.claim && !state.revoked.contains(.playback) }) ?? true,
                      capture.map({ state.reserved[.capture] == $0.claim && !state.revoked.contains(.capture) }) ?? true else { return false }
                state.generation = generation
                if let playback { state.committed[.playback] = playback.claim }
                if let capture { state.committed[.capture] = capture.claim }
                return true
            }
            guard committed else { throw CancellationError() }
        } catch {
            quarantine(error.localizedDescription)
            do { try driver.stop() }
            catch { quarantine("Audio cleanup failed: " + error.localizedDescription) }
            throw error
        }
    }

    private func validateRoles() throws {
        if let playback, !(isReserved(playback.claim) && playback.authorization() == .current) { throw CancellationError() }
        if let capture, !(isReserved(capture.claim) && capture.permitted() && driver.recordPermissionGranted) {
            throw CancellationError()
        }
    }

    private func quarantine(_ message: String) {
        let owner = claims.withLock { state -> UUID? in
            state.generation = nil
            state.committed.removeAll()
            state.revoked.formUnion(state.reserved.keys)
            state.problem = String(message.prefix(240))
            return state.lease.owner
        }
        let stopped = capture?.stopped
        capture = nil
        if let owner {
            let problem = cleanupProblem(owner: owner)
            Array(problemHandlers.values).forEach { $0(problem) }
        }
        stopped?(message)
    }
}
