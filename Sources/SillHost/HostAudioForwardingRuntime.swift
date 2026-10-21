import Foundation
import StreamProtocol

@MainActor
final class HostAudioForwardingRuntime {
    private final class RequestAdmission: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    @MainActor
    private final class ConnectionLease {
        struct Observation {
            let credential: AudioForwardingCredential
            let configuration: AudioForwardingConfiguration
            let generation: UUID
        }
        let id: UUID
        let peer: AudioForwardingPairedDevice
        let principal: AudioForwardingCatalog.Principal
        var connectionIsCurrent: () -> Bool
        var observation: Observation?
        var evidenceGeneration = UUID()
        var attached = false
        var busy = false
        var renewing = false
        var lastRenewal = ContinuousClock.now
        var nativeTransport: UUID?

        init(_ context: AudioForwardingConnectionContext) {
            id = context.connectionID; peer = context.peer; principal = context.principal
            connectionIsCurrent = context.connectionIsCurrent
        }

        func matches(_ context: AudioForwardingConnectionContext) -> Bool {
            id == context.connectionID && peer.id == context.peer.id &&
            peer.pairingGeneration == context.peer.pairingGeneration &&
            principal.kind == context.principal.kind && principal.id == context.principal.id &&
            principal.authorizationGeneration == context.principal.authorizationGeneration
        }
    }

    private let privacy: HostAudioPrivacy
    private let sentry: HostSentry
    private let prepareProtection: @MainActor () -> Bool
    private let participants: AudioForwardingParticipants
    private var relay: LocalAudioRelay?
    private var connections: [UUID: ConnectionLease] = [:]
    private var generation = UUID()
    private var stopped = false
    private var running = false
    private var startWork: Task<Void, Never>?
    private var configuration: AudioForwardingConfiguration?
    private var attemptedConfiguration: AudioForwardingConfiguration?
    private var configuring: UUID?
    private var monitor: UUID?
    private var polling = false
    private var reconciliation: UUID?
    private var offered: AudioForwardingBinding?
    private var offeredWantsAudio = false
    private var pendingSnapshot: AudioForwardingSnapshot?
    private var preparedScope: AudioForwardingCoordinator.Scope?
    private var committedScope: AudioForwardingCoordinator.Scope?
    private var observedRevision: UInt64?

    private lazy var protection = AudioForwardingProtection(audio: privacy, sentry: sentry,
        configuration: { [weak self] in self?.currentConfiguration })

    private lazy var coordinator = AudioForwardingCoordinator(dependencies: .init(
        configuration: { [weak self] in self?.currentConfiguration },
        snapshot: { [weak self] in await self?.snapshot() },
        fence: { [weak self] _ in
            self?.participants.invalidate()
            self?.protection.invalidate()
            self?.preparedScope = nil
            self?.committedScope = nil
        },
        prepare: { [weak self] scope, request in
            guard let self, self.currentConfiguration == scope.binding.configuration else { return nil }
            if self.preparedScope != scope {
                guard self.participants.begin(scope) else { return nil }
                self.preparedScope = scope
            }
            return await self.participants.prepare(scope, request: request,
                until: ContinuousClock.now.advanced(by: .milliseconds(request.budgetMilliseconds)))
        },
        inspect: { [weak self] scope, request in
            guard let self, self.currentConfiguration == scope.binding.configuration else { return nil }
            return await self.participants.inspect(scope, request: request,
                until: ContinuousClock.now.advanced(by: .milliseconds(request.budgetMilliseconds)))
        },
        protection: { [weak self] scope, deadline in
            guard let self, self.bindingIsCurrent(scope.binding) else { return nil }
            return self.protection.readback(scope, until: deadline)
        },
        protectionCurrent: { [weak self] proof in
            guard let self, self.bindingIsCurrent(proof.scope.binding) else { return false }
            return self.protection.current(proof)
        },
        commit: { [weak self] commit in
            guard let self, let relay = self.relay, self.currentConfiguration == commit.configuration else { return nil }
            return await relay.forwardingCommit(commit)
        }))

    init(privacy: HostAudioPrivacy, sentry: HostSentry, prepareProtection: @escaping @MainActor () -> Bool) {
        self.privacy = privacy; self.sentry = sentry
        self.prepareProtection = prepareProtection
        participants = AudioForwardingParticipants(registry: privacy.participants)
    }

    func start() async {
        guard !stopped else { return }
        if let startWork { await startWork.value; return }
        let work = Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            do {
                let relay = try LocalAudioRelayLaunch.makeForwardingRelay(participants: self.privacy.participants)
                self.relay = relay
                guard await relay.start(), !self.stopped, self.relay === relay else { return }
                self.running = true
                await self.configure()
            } catch {
                self.running = false
            }
        }
        startWork = work
        await work.value
    }

    func handle(_ control: AudioForwardingControl,
                context: AudioForwardingConnectionContext) async -> AudioForwardingState? {
        guard !Task.isCancelled, context.isCurrent(), context.connectionIsCurrent() else { return nil }
        let generation = self.generation, configuration = currentConfiguration
        // 호출자 취소는 공유 pipe의 in-flight RPC를 취소하지 않는다.
        let admission = RequestAdmission()
        let state = await withTaskCancellationHandler {
            let work = Task { @MainActor [weak self] in
                await self?.exchange(control, context: context, admission: admission)
            }
            return await work.value
        } onCancel: { admission.cancel() }
        guard let state, responseIsCurrent(state), !Task.isCancelled, self.generation == generation,
              currentConfiguration == configuration, context.isCurrent(), context.connectionIsCurrent() else { return nil }
        return state
    }

    private func exchange(_ control: AudioForwardingControl,
                          context: AudioForwardingConnectionContext, admission: RequestAdmission) async -> AudioForwardingState? {
        guard running, !stopped, context.isCurrent(), context.connectionIsCurrent(),
              context.principal.id == context.peer.id,
              context.principal.authorizationGeneration == context.peer.pairingGeneration else { return nil }
        let lease: ConnectionLease
        if let existing = connections[context.connectionID] {
            guard existing.matches(context), !existing.busy else { return nil }
            lease = existing
            lease.connectionIsCurrent = context.connectionIsCurrent
        } else {
            guard control.operation == .observe else { return nil }
            lease = ConnectionLease(context)
            connections[lease.id] = lease
        }
        startMonitor()
        guard let expected = currentConfiguration, let relay else { return nil }
        let generation = self.generation
        let admitted = { [weak self, weak lease] in
            guard let self, let lease else { return false }
            return !admission.isCancelled && self.owns(lease, generation: generation, configuration: expected) && context.isCurrent()
        }
        guard admitted() else { return nil }
        lease.busy = true
        defer { lease.busy = false }
        switch control.operation {
        case .observe:
            guard case .accepted(let bootstrap) = await relay.forwardingBootstrap(peer: lease.peer, admission: admitted),
                  admitted() else { return nil }
            let hadObservation = lease.observation != nil
            let evidenceGeneration = UUID()
            lease.evidenceGeneration = evidenceGeneration
            defer {
                if !hadObservation, lease.observation == nil, lease.evidenceGeneration == evidenceGeneration {
                    lease.attached = false
                    detach(lease, evidenceGeneration: evidenceGeneration)
                }
            }
            guard case .accepted(let snapshot) = await relay.forwardingEvidence(peer: lease.peer,
                connectionID: lease.id, operation: .attach, admission: admitted), admitted(),
                  let visible = visibleSnapshot(snapshot),
                  let observed = try? AudioForwardingBootstrap(credential: bootstrap.credential,
                    ownCursor: bootstrap.ownCursor, snapshot: visible),
                  let catalog = try? AudioForwardingCatalog(principal: context.principal, role: context.role, bootstrap: observed),
                  let state = try? AudioForwardingState(requestID: control.requestID, operation: .observe, catalog: catalog, result: nil),
                  admitted() else { return nil }
            lease.lastRenewal = ContinuousClock.now
            lease.attached = true
            lease.observation = .init(credential: bootstrap.credential, configuration: expected, generation: generation)
            offer(snapshot)
            return state
        case .submit:
            guard let observation = lease.observation, observation.generation == generation,
                  observation.configuration == expected, let intent = control.intent,
                  intent.transportKind == .native, intent.pairedDeviceId == lease.peer.id else { return nil }
            guard let result = await relay.forwardingRequest(intent, peer: lease.peer,
                credential: observation.credential, admission: admitted), admitted() else { return nil }
            switch result {
            case .accepted(let snapshot):
                    offer(snapshot)
                guard let visible = visibleSnapshot(snapshot), admitted() else { return nil }
                return try? .init(requestID: control.requestID, operation: .submit, catalog: nil, result: .accepted(visible))
            case .refused(let code, let snapshot):
                offer(snapshot)
                guard let visible = visibleSnapshot(snapshot), admitted() else { return nil }
                return try? .init(requestID: control.requestID, operation: .submit, catalog: nil,
                    result: .refused(code: code, snapshot: visible))
            }
        }
    }

    func connectionClosed(_ id: UUID) {
        guard let lease = connections.removeValue(forKey: id) else { return }
        lease.observation = nil
        if let binding = offered, !bindingIsCurrent(binding) {
            fenceWork()
            if offeredWantsAudio { disconnect(binding) }
        }
        if lease.attached { detach(lease, evidenceGeneration: lease.evidenceGeneration) }
        if connections.isEmpty { monitor = nil }
    }

    func invalidateProtection() {
        let old = offered
        generation = UUID()
        configuration = nil
        attemptedConfiguration = nil
        for lease in connections.values { lease.observation = nil }
        fenceWork()
        offered = nil; pendingSnapshot = nil
        observedRevision = nil
        if let old, offeredWantsAudio { disconnect(old) }
        if running, !stopped { Task { @MainActor [weak self] in await self?.configure() } }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; running = false; generation = UUID(); monitor = nil
        configuration = nil; pendingSnapshot = nil
        connections.removeAll()
        fenceWork()
        relay?.stop()
        relay = nil
    }

    private var currentConfiguration: AudioForwardingConfiguration? {
        guard running, !stopped, configuring == nil, let configuration,
              relay?.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration) == configuration else { return nil }
        return configuration
    }

    private func owns(_ lease: ConnectionLease, generation: UUID, configuration: AudioForwardingConfiguration) -> Bool {
        self.generation == generation && connections[lease.id] === lease && lease.connectionIsCurrent() &&
        currentConfiguration == configuration
    }

    private func configure() async {
        guard running, !stopped, configuring == nil, let relay,
              let expected = relay.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration),
              configuration != expected, attemptedConfiguration != expected else { return }
        let token = UUID(), generation = self.generation
        configuring = token; attemptedConfiguration = expected
        configuration = nil
        fenceWork()
        let result = await relay.forwardingConfigure(privacyGeneration: expected.privacyGeneration,
            admission: { [weak self] in
                guard let self else { return false }
                return !self.stopped && self.relay === relay && self.generation == generation &&
                    self.configuring == token &&
                    relay.forwardingConfiguration(privacyGeneration: self.privacy.forwardingPrivacyGeneration) == expected
            })
        guard configuring == token else { return }
        configuring = nil
        guard !stopped, self.relay === relay, self.generation == generation,
              relay.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration) == expected,
              case .accepted(let snapshot) = result,
              snapshot.binding == nil || snapshot.binding?.configuration == expected else { return }
        configuration = expected
        offer(snapshot)
    }

    private func startMonitor() {
        guard monitor == nil, running, !stopped, !connections.isEmpty else { return }
        let token = UUID()
        monitor = token
        Task { @MainActor [weak self] in
            while let self, self.monitor == token, !self.stopped, !self.connections.isEmpty {
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tick() {
        for lease in Array(connections.values) {
            if !lease.connectionIsCurrent() { connectionClosed(lease.id); continue }
            if lease.attached, lease.observation != nil, !lease.renewing,
               ContinuousClock.now >= lease.lastRenewal.advanced(by: .seconds(5)) {
                renew(lease)
            }
        }
        guard !connections.isEmpty else { return }
        if configuration != nil, currentConfiguration == nil { invalidateProtection() }
        if currentConfiguration == nil {
            Task { @MainActor [weak self] in await self?.configure() }
            return
        }
        guard !polling else { return }
        polling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.polling = false }
            guard let snapshot = await self.snapshot() else { return }
            self.offer(snapshot)
        }
    }

    private func renew(_ lease: ConnectionLease) {
        guard let relay, let configuration = currentConfiguration else { return }
        lease.renewing = true
        let generation = self.generation
        Task { @MainActor [weak self, weak lease] in
            guard let self, let lease else { return }
            defer { lease.renewing = false }
            let admitted = { [weak self, weak lease] in
                guard let self, let lease, let observation = lease.observation,
                      observation.generation == generation, observation.configuration == configuration else { return false }
                return self.owns(lease, generation: generation, configuration: configuration)
            }
            guard admitted(), case .accepted(let snapshot) = await relay.forwardingEvidence(peer: lease.peer,
                connectionID: lease.id, operation: .renew, admission: admitted), admitted() else { return }
            lease.lastRenewal = ContinuousClock.now
            self.offer(snapshot)
        }
    }

    private func detach(_ lease: ConnectionLease, evidenceGeneration: UUID) {
        guard let relay else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let admitted = { [weak self] in
                guard let self, !self.stopped, self.relay === relay else { return false }
                if let current = self.connections[lease.id] {
                    return current === lease && current.evidenceGeneration == evidenceGeneration && current.observation == nil
                }
                return true
            }
            guard admitted() else { return }
            _ = await relay.forwardingEvidence(peer: lease.peer, connectionID: lease.id, operation: .detach, admission: admitted)
        }
    }

    private func snapshot() async -> AudioForwardingSnapshot? {
        guard let relay, let expected = currentConfiguration else { return nil }
        let generation = self.generation
        guard case .accepted(let snapshot) = await relay.forwardingSnapshot(),
              self.generation == generation, currentConfiguration == expected,
              snapshot.binding == nil || snapshot.binding?.configuration == expected else { return nil }
        return snapshot
    }

    private func bindingIsCurrent(_ binding: AudioForwardingBinding) -> Bool {
        guard currentConfiguration == binding.configuration else { return false }
        return connections.values.contains { lease in
            guard let observation = lease.observation, lease.attached, lease.connectionIsCurrent(),
                  lease.peer.id == binding.pairedDeviceId, observation.generation == generation,
                  observation.configuration == binding.configuration else { return false }
            return binding.transportKind == .http || lease.nativeTransport == binding.transportId
        }
    }

    private func visibleSnapshot(_ snapshot: AudioForwardingSnapshot) -> AudioForwardingSnapshot? {
        guard let binding = snapshot.binding, binding.phase == .active else { return snapshot }
        guard let scope = committedScope, scope.matches(snapshot, committed: true),
              privacy.forwardingHealth(), sentry.forwardingProof() != nil, coordinator.isCurrent(scope) else {
            return try? .init(revision: snapshot.revision, intent: snapshot.intent, binding: nil)
        }
        return snapshot
    }

    private func responseIsCurrent(_ state: AudioForwardingState) -> Bool {
        let snapshot: AudioForwardingSnapshot?
        if let catalog = state.catalog { snapshot = catalog.bootstrap.snapshot }
        else {
            switch state.result {
            case .accepted(let value): snapshot = value
            case .refused(_, let value): snapshot = value
            case nil: snapshot = nil
            }
        }
        guard let snapshot, snapshot.binding?.phase == .active else { return true }
        return visibleSnapshot(snapshot)?.binding?.phase == .active
    }

    private func offer(_ snapshot: AudioForwardingSnapshot) {
        guard currentConfiguration != nil,
              observedRevision.map({ snapshot.revision.value >= $0 }) != false else { return }
        observedRevision = snapshot.revision.value
        guard let binding = snapshot.binding else {
            fenceWork(); offered = nil; pendingSnapshot = nil
            return
        }
        guard bindingIsCurrent(binding) else { return }
        if binding.phase == .active {
            if let scope = committedScope, scope.matches(snapshot, committed: true),
               privacy.forwardingHealth(), sentry.forwardingProof() != nil, coordinator.isCurrent(scope) { return }
            if reconciliation != nil { return }
            fenceWork(); disconnect(binding)
            return
        }
        guard binding.phase == .quiescing else { return }
        guard binding != offered else { return }
        pendingSnapshot = snapshot
        launchReconciliation()
    }

    private func launchReconciliation() {
        guard reconciliation == nil, let snapshot = pendingSnapshot, let binding = snapshot.binding,
              bindingIsCurrent(binding) else { return }
        pendingSnapshot = nil; offered = binding
        offeredWantsAudio = snapshot.intent?.inputDesired == true || snapshot.intent?.outputDesired == true
        let token = UUID(), generation = self.generation
        reconciliation = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reconciliation == token {
                    self.reconciliation = nil
                    self.launchReconciliation()
                }
            }
            guard self.generation == generation, self.bindingIsCurrent(binding) else { return }
            if !self.privacy.forwardingHealth() || self.sentry.forwardingProof() == nil {
                let prepared = self.prepareProtection()
                guard self.generation == generation, self.currentConfiguration == binding.configuration else {
                    if self.generation == generation, !self.stopped { self.invalidateProtection() }
                    return
                }
                guard prepared, self.bindingIsCurrent(binding), self.privacy.forwardingHealth(),
                      self.sentry.forwardingProof() != nil else {
                    self.disconnect(binding)
                    return
                }
            }
            let outcome = await self.coordinator.reconcile(snapshot)
            guard self.reconciliation == token else { return }
            if self.generation == generation, self.bindingIsCurrent(binding) {
                if case .committed(let scope, _) = outcome { self.committedScope = scope }
                else { self.disconnect(binding) }
            }
        }
    }

    private func fenceWork() {
        coordinator.invalidate()
        participants.invalidate()
        protection.invalidate()
        preparedScope = nil; committedScope = nil
    }

    private func connectionOwners(_ binding: AudioForwardingBinding) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for lease in connections.values {
            guard lease.attached, lease.connectionIsCurrent(), let observation = lease.observation,
                  lease.peer.id == binding.pairedDeviceId,
                  observation.configuration == binding.configuration,
                  binding.transportKind == .http || lease.nativeTransport == binding.transportId else { continue }
            result[lease.id] = lease.evidenceGeneration
        }
        return result
    }

    private func disconnect(_ binding: AudioForwardingBinding) {
        guard binding.phase != .off, let relay else { return }
        let generation = self.generation, configuration = currentConfiguration
        let owners = connectionOwners(binding)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await relay.forwardingDisconnect(binding, admission: { [weak self] in
                guard let self else { return false }
                return !self.stopped && self.relay === relay && self.generation == generation &&
                    self.currentConfiguration == configuration && self.connectionOwners(binding) == owners &&
                    (self.offered == nil || self.offered?.bindingEpoch == binding.bindingEpoch)
            })
        }
    }
}
