import Foundation
import StreamProtocol

@MainActor
protocol HostMicrophoneSink: AnyObject {
    func close() async -> String?
    func retryClose() async -> String?
    func runtimeValid() -> Bool
}

extension HostMicrophoneSink {
    func retryClose() async -> String? { await close() }
}

@MainActor
struct HostMicrophonePreparation {
    let resource: (any HostMicrophoneSink)?
    let error: String?
}

@MainActor
final class HostMicrophoneReceiver {
    enum Phase: Equatable { case off, preparing, active, retiring, cleanupFailed }
    private final class Lease {
        let serial: UInt64
        let id = UUID()
        let request: MicrophoneControl
        let owner: HostLocalOwnerGrant
        let render: MicrophoneRenderBuffer
        var resource: (any HostMicrophoneSink)?
        var preparePending = true
        var closing = false
        var stopRequest: UUID?
        var retirementReason: String?
        var lastSequence: UInt64 = 0
        var admitted: UInt64 = 0
        var lastArrival: UInt64
        init(serial: UInt64, request: MicrophoneControl, owner: HostLocalOwnerGrant, now: UInt64, clock: @escaping () -> UInt64) {
            self.serial = serial; self.request = request; self.owner = owner
            render = MicrophoneRenderBuffer(grant: owner, now: clock); lastArrival = now
        }
    }
    private struct Outcome {
        let request: MicrophoneControl
        let fingerprint: Data
        var state: MicrophoneState
        var cancelled = false
    }
    private(set) var phase = Phase.off
    private var lease: Lease?
    private var outcomes: [UUID: Outcome] = [:]
    private var serial: UInt64 = 0
    private var advertised: [UUID: HostLocalOwnerGrant] = [:]
    private let capacity: Int
    private let serialLimit: UInt64
    private let now: () -> UInt64
    private let prepare: @MainActor (HostLocalOwnerGrant, MicrophoneRenderBuffer) async -> HostMicrophonePreparation
    private let provider: (any HostMicrophoneOriginalOwner)?
    private var watchdog: Task<Void, Never>?
    var availabilityChanged: (() -> Void)?
    var current: ((MicrophoneScope, Data) -> Bool)?
    var sendState: ((MicrophoneState, MicrophoneRenderBuffer?) -> Void)?
    var sendReceipt: ((MicrophoneReceipt) -> Void)?
    var onRenderGate: ((MicrophoneControl, UUID, MicrophoneRenderBuffer) -> Void)?
    private let automaticWatchdog: Bool
    private let backendAvailable: Bool

    init(provider: (any HostMicrophoneOriginalOwner)? = nil, capacity: Int = 128, serialLimit: UInt64 = .max,
         automaticWatchdog: Bool = true, backendAvailable: Bool = true, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         prepare: @escaping @MainActor (HostLocalOwnerGrant, MicrophoneRenderBuffer) async -> HostMicrophonePreparation = { grant, render in
             await HALMicrophoneSink.prepare(grant: grant, render: render)
         }) {
        self.provider = provider; self.capacity = max(2, min(capacity, 1024)); self.serialLimit = serialLimit
        self.automaticWatchdog = automaticWatchdog; self.backendAvailable = backendAvailable
        self.now = now; self.prepare = prepare
    }

    func capability(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID,
                    fingerprint: Data) -> MicrophoneCapability? {
        guard backendAvailable, phase == .off, outcomes.count < capacity - 1, serial < serialLimit,
              advertised[peer] != nil || advertised.count < 32,
              let grant = provider?.microphoneGrant(peer: peer, source: source, inputGeneration: inputGeneration,
                                                   videoEpoch: videoEpoch, fingerprint: fingerprint),
              grant.scope.peer == peer, grant.scope.source == source,
              grant.scope.inputGeneration == inputGeneration, grant.scope.videoEpoch == videoEpoch,
              current?(grant.scope, fingerprint) == true,
              valid(grant, scope: grant.scope, fingerprint: fingerprint) else { return nil }
        advertised[peer] = grant
        return MicrophoneCapability(peer: peer, destination: grant.scope.destination, generation: grant.scope.capability)
    }

    func advertisedGrant(peer: UUID) -> HostLocalOwnerGrant? { advertised[peer] }

    func forgetCapabilities(peer: UUID? = nil, fingerprint: Data? = nil) {
        let keys = advertised.keys.filter { key in
            (peer == nil || key == peer) && (fingerprint == nil || advertised[key]?.fingerprint == fingerprint)
        }
        for key in keys { advertised.removeValue(forKey: key)?.revoke() }
    }

    private func valid(_ grant: HostLocalOwnerGrant, scope: MicrophoneScope, fingerprint: Data) -> Bool {
        grant.scope == scope && grant.fingerprint == fingerprint && !fingerprint.isEmpty && grant.valid(at: now())
    }

    func control(_ request: MicrophoneControl, fingerprint: Data) {
        if request.operation == .stop && (request.grantID == nil || outcomes[request.requestID]?.request.operation == .start) {
            cancelStart(request, fingerprint: fingerprint)
            return
        }
        if let prior = outcomes[request.requestID] {
            if prior.cancelled, prior.request.scope == request.scope, prior.fingerprint == fingerprint {
                publish(prior.state)
                return
            }
            guard prior.request == request, prior.fingerprint == fingerprint else { refuse(request, "request conflict"); return }
            publish(prior.state)
            return
        }
        if request.operation != .start {
            guard let owned = lease, request.scope == owned.request.scope, request.grantID == owned.id,
                  fingerprint == owned.owner.fingerprint else { refuse(request, "foreign lease"); return }
            if request.operation == .stop {
                if let stopID = owned.stopRequest, stopID != request.requestID { refuse(request, "stop already recorded"); return }
                owned.stopRequest = request.requestID
                revoke(reason: "stopped")
                record(request, state(for: owned, requestID: request.requestID))
            } else {
                guard phase == .active, live(owned) else { revoke(reason: "scope lost"); return }
                let counters = owned.render.counters
                sendReceipt?(MicrophoneReceipt(scope: request.scope, grantID: owned.id, admittedPackets: owned.admitted,
                                               renderedFrames: counters.0, applicationQueueAgeMilliseconds: counters.1))
            }
            return
        }
        guard outcomes.count < capacity - 1 else { refuse(request, "action capacity exhausted"); return }
        guard phase == .off, lease == nil else { record(request, refused(request, "busy"), fingerprint: fingerprint); return }
        guard serial < serialLimit else { record(request, refused(request, "lease IDs exhausted"), fingerprint: fingerprint); return }
        guard backendAvailable, request.grantID == nil, current?(request.scope, fingerprint) == true,
              let grant = advertised[request.scope.peer],
              valid(grant, scope: request.scope, fingerprint: fingerprint) else {
            record(request, refused(request, "unsupported"), fingerprint: fingerprint); return
        }
        serial += 1
        let owned = Lease(serial: serial, request: request, owner: grant, now: now(), clock: now)
        lease = owned; phase = .preparing
        onRenderGate?(request, owned.id, owned.render)
        record(request, state(for: owned))
        if automaticWatchdog {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.checkWatchdog()
                }
            }
        }
        Task { [self, owned] in
            let result = await prepare(owned.owner, owned.render)
            owned.preparePending = false
            owned.resource = result.resource
            guard lease === owned, phase == .preparing, result.error == nil, result.resource != nil, live(owned) else {
                owned.render.close()
                if lease === owned, phase == .preparing {
                    revoke(reason: result.error ?? "preparation superseded")
                } else {
                    await retire(owned)
                }
                return
            }
            phase = .active
            record(owned.request, state(for: owned))
        }
    }

    private func cancelStart(_ request: MicrophoneControl, fingerprint: Data) {
        if let prior = outcomes[request.requestID] {
            guard (prior.request.operation == .start || prior.cancelled), prior.request.scope == request.scope,
                  prior.fingerprint == fingerprint, request.grantID == nil || prior.state.grantID == request.grantID else { refuse(request, "foreign cancellation"); return }
            if let owned = lease, owned.request.requestID == request.requestID, owned.request.scope == request.scope,
               owned.owner.fingerprint == fingerprint {
                revoke(reason: "start cancelled")
                outcomes[request.requestID]?.cancelled = true
                return
            }
            var cancelled = prior
            cancelled.cancelled = true
            cancelled.state = MicrophoneState(requestID: request.requestID, scope: request.scope, phase: .off,
                                               grantID: prior.state.grantID, reason: "start cancelled")
            outcomes[request.requestID] = cancelled
            publish(cancelled.state)
            return
        }
        guard outcomes.count < capacity - 1 else { refuse(request, "action capacity exhausted"); return }
        guard current?(request.scope, fingerprint) == true, let grant = advertised[request.scope.peer],
              valid(grant, scope: request.scope, fingerprint: fingerprint) else { refuse(request, "foreign cancellation"); return }
        let state = MicrophoneState(requestID: request.requestID, scope: request.scope, phase: .off,
                                    grantID: nil, reason: "start cancelled")
        outcomes[request.requestID] = Outcome(request: request, fingerprint: fingerprint, state: state, cancelled: true)
        publish(state)
    }

    func retryCleanup(grantID: UUID) {
        guard phase == .cleanupFailed, let owned = lease, owned.id == grantID, !owned.closing else { return }
        phase = .retiring
        updateOutcomes(owned, reason: "explicit cleanup retry")
        Task { [self, owned] in await retire(owned, retry: true) }
    }

    private func live(_ owned: Lease) -> Bool {
        owned.render.isOpen && owned.owner.valid(at: now()) &&
        current?(owned.request.scope, owned.owner.fingerprint) == true
    }

    func frame(_ frame: MicrophoneFrame, fingerprint: Data, arrived: UInt64) -> Bool {
        guard let owned = lease, phase == .active, frame.scope == owned.request.scope,
              frame.grantID == owned.id, fingerprint == owned.owner.fingerprint, live(owned), owned.render.isAdmitted,
              frame.sequence > owned.lastSequence, frame.sequence - owned.lastSequence <= 4096,
              owned.admitted < UInt64.max else { return false }
        guard owned.render.offer(frame, arrived: arrived, now: now()) else { return false }
        owned.lastSequence = frame.sequence; owned.admitted += 1; owned.lastArrival = now()
        return true
    }

    func revoke(peer: UUID? = nil, reason: String) {
        guard let owned = lease, peer == nil || owned.request.scope.peer == peer else { return }
        if owned.retirementReason == nil { owned.retirementReason = String(reason.prefix(160)) }
        owned.render.close()
        guard phase != .cleanupFailed, phase != .retiring else { return }
        phase = .retiring
        watchdog?.cancel(); watchdog = nil
        updateOutcomes(owned, reason: owned.retirementReason)
        if !owned.preparePending { Task { [self, owned] in await retire(owned) } }
    }

    func checkWatchdog() {
        guard let owned = lease, phase == .active || phase == .preparing else { return }
        let time = now()
        if !live(owned) || time < owned.lastArrival || time - owned.lastArrival > 2_000_000_000 {
            revoke(reason: "grant expired or ingress idle")
        } else if phase == .active, owned.resource?.runtimeValid() != true {
            revoke(reason: "destination changed")
        }
    }

    private func retire(_ owned: Lease, retry: Bool = false) async {
        if !retry, phase == .cleanupFailed { return }
        guard !owned.preparePending, !owned.closing else { return }
        owned.closing = true
        owned.render.close()
        let error: String?
        if retry { error = await owned.resource?.retryClose() }
        else { error = await owned.resource?.close() }
        guard lease === owned else { return }
        if let error {
            owned.closing = false
            phase = .cleanupFailed
            updateOutcomes(owned, reason: error)
        } else {
            phase = .off
            updateOutcomes(owned, reason: owned.retirementReason)
            lease = nil
            availabilityChanged?()
        }
    }

    private func state(for owned: Lease, requestID: UUID? = nil, reason: String? = nil) -> MicrophoneState {
        let wirePhase: MicrophoneState.Phase
        switch phase {
        case .off: wirePhase = .off
        case .preparing: wirePhase = .preparing
        case .active: wirePhase = .active
        case .retiring: wirePhase = .retiring
        case .cleanupFailed: wirePhase = .cleanupFailed
        }
        return MicrophoneState(requestID: requestID ?? owned.request.requestID, scope: owned.request.scope,
                               phase: wirePhase, grantID: owned.id, reason: reason)
    }

    private func updateOutcomes(_ owned: Lease, reason: String?) {
        let keys = outcomes.keys.filter { outcomes[$0]?.state.grantID == owned.id }
        for key in keys {
            guard var outcome = outcomes[key] else { continue }
            outcome.state = state(for: owned, requestID: key, reason: reason)
            outcomes[key] = outcome
            publish(outcome.state)
        }
    }
    private func record(_ request: MicrophoneControl, _ state: MicrophoneState, fingerprint: Data? = nil) {
        outcomes[request.requestID] = Outcome(request: request, fingerprint: fingerprint ?? lease?.owner.fingerprint ?? Data(), state: state)
        publish(state)
    }
    private func publish(_ state: MicrophoneState) {
        if state.phase == .active {
            guard let owned = lease, state.grantID == owned.id, phase == .active, live(owned) else { return }
            sendState?(state, owned.render)
        } else { sendState?(state, nil) }
    }
    private func refused(_ request: MicrophoneControl, _ reason: String) -> MicrophoneState {
        MicrophoneState(requestID: request.requestID, scope: request.scope, phase: .refused, grantID: nil, reason: reason)
    }
    private func refuse(_ request: MicrophoneControl, _ reason: String) { publish(refused(request, reason)) }
}
