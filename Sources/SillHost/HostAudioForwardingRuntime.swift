import Foundation
import StreamProtocol

@MainActor
struct AudioForwardingConnectionContext {
    let peer: AudioForwardingPairedDevice
    let principal: AudioForwardingCatalog.Principal
    let role: AudioForwardingCatalog.Role
    let connectionID: UUID
    let connectionIsCurrent: () -> Bool
    let isCurrent: () -> Bool
}

@MainActor
final class HostAudioForwardingRuntime {
    private struct Session {
        let context: AudioForwardingConnectionContext
        let credential: AudioForwardingCredential
        let generation = UUID()
    }
    private final class Enrollment {
        let context: AudioForwardingConnectionContext
        let relay: LocalAudioRelay
        var submitted = false
        init(_ context: AudioForwardingConnectionContext, relay: LocalAudioRelay) {
            self.context = context; self.relay = relay
        }
    }
    private var relay: LocalAudioRelay
    private let replacement: (() throws -> LocalAudioRelay)?
    private var enrollments: [UUID: Enrollment] = [:]
    private var evidenceRevision = UUID()
    private var recovering: Task<Void, Never>?
    private var recoveryNeeded = false
    private var recoveryBlocked = false
    private var recoveryContexts: [AudioForwardingConnectionContext] = []
    private var retiredRelay: LocalAudioRelay?
    private let privacy: HostAudioPrivacy
    private let sentry: HostSentry
    private let participants: AudioForwardingParticipants
    private lazy var protection = AudioForwardingProtection(audio: privacy, sentry: sentry,
        configuration: { [weak self] in self?.configuration })
    private let fenceMedia: () -> Void
    private let commitMedia: (AudioForwardingCoordinator.Scope?) -> Void
    private var sessions: [UUID: Session] = [:]
    private var retiringSessions: [UUID: Session] = [:]
    private var polling: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var preparing: UUID?
    private var preparingBinding: AudioForwardingBinding?
    private var active: AudioForwardingCoordinator.Scope?
    private var running = false
    private var revision = UUID()
    private(set) var snapshot: AudioForwardingSnapshot?

    private lazy var coordinator = AudioForwardingCoordinator(dependencies: .init(
        configuration: { [weak self] in self?.configuration },
        snapshot: { [weak self] in await self?.readSnapshot() },
        fence: { [weak self] scope in
            guard let self else { return }
            self.active = nil
            self.fenceMedia()
            _ = self.participants.begin(scope)
        },
        prepare: { [weak self] scope, request in
            guard let self else { return nil }
            return await self.participants.prepare(scope, request: request,
                until: .now.advanced(by: .milliseconds(request.budgetMilliseconds)))
        },
        inspect: { [weak self] scope, request in
            guard let self else { return nil }
            return await self.participants.inspect(scope, request: request,
                until: .now.advanced(by: .milliseconds(request.budgetMilliseconds)))
        },
        protection: { [weak self] scope, deadline in self?.protection.readback(scope, until: deadline) },
        protectionCurrent: { [weak self] proof in self?.protection.current(proof) == true },
        commit: { [weak self] command in await self?.relay.forwardingCommit(command) }
    ))

    init(relay: LocalAudioRelay, privacy: HostAudioPrivacy, sentry: HostSentry,
         replacement: (() throws -> LocalAudioRelay)? = nil,
         fenceMedia: @escaping () -> Void,
         commitMedia: @escaping (AudioForwardingCoordinator.Scope?) -> Void) {
        self.relay = relay
        self.replacement = replacement
        self.privacy = privacy
        self.sentry = sentry
        self.fenceMedia = fenceMedia
        self.commitMedia = commitMedia
        participants = AudioForwardingParticipants(registry: privacy.participants)
    }

    private var configuration: AudioForwardingConfiguration? {
        relay.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration)
    }

    func start() async -> Bool {
        guard !running, await relay.start(),
              case .accepted(let initial) = await relay.forwardingConfigure(
                privacyGeneration: privacy.forwardingPrivacyGeneration) else { return false }
        running = true
        observe(initial)
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.running {
                await self.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        return true
    }

    func exchange(_ control: AudioForwardingControl,
                  context: AudioForwardingConnectionContext) async -> AudioForwardingState? {
        guard running, recovering == nil, !recoveryNeeded, !recoveryBlocked, context.isCurrent(),
              let bootstrap = await enroll(context), context.isCurrent() else { return nil }
        if control.operation == .observe {
            guard let catalog = try? AudioForwardingCatalog(principal: context.principal,
                role: context.role, bootstrap: bootstrap) else { return nil }
            return try? AudioForwardingState(requestID: control.requestID, operation: .observe,
                catalog: catalog, result: nil)
        }
        guard privacy.forwardingIntentAllowed, let intent = control.intent, intent.pairedDeviceId == context.peer.id,
              intent.transportKind == .native, let session = sessions[context.connectionID],
              context.isCurrent() else { return nil }
        if !privacy.latched { _ = privacy.armAndVerify() }
        _ = sentry.activate()
        guard case .accepted = await relay.forwardingConfigure(
            privacyGeneration: privacy.forwardingPrivacyGeneration), context.isCurrent(), privacy.forwardingIntentAllowed,
              let result = await relay.forwardingRequest(intent, peer: context.peer,
                credential: session.credential, admission: { [weak privacy] in
                    context.isCurrent() && privacy?.forwardingIntentAllowed == true
                }), context.isCurrent(), privacy.forwardingIntentAllowed else { return nil }
        switch result {
        case .accepted(let value), .refused(_, let value): observe(value)
        }
        return try? AudioForwardingState(requestID: control.requestID, operation: .submit,
            catalog: nil, result: result)
    }

    private func enroll(_ context: AudioForwardingConnectionContext) async -> AudioForwardingBootstrap? {
        guard context.isCurrent(), privacy.forwardingIntentAllowed, running else { return nil }
        if !privacy.latched { _ = privacy.armAndVerify() }
        let owner = Enrollment(context, relay: relay)
        let generation = evidenceRevision
        enrollments[context.connectionID] = owner
        let admitted = { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return self.running && !self.recoveryBlocked && self.relay === owner.relay &&
                self.privacy.forwardingIntentAllowed && self.evidenceRevision == generation &&
                self.enrollments[context.connectionID] === owner && context.isCurrent()
        }
        var retained = false
        defer {
            if enrollments[context.connectionID] === owner { enrollments.removeValue(forKey: context.connectionID) }
            if !retained, owner.submitted, relay === owner.relay { resetAfterUncertainEvidence() }
        }
        guard admitted(), case .accepted = await owner.relay.forwardingConfigure(
                privacyGeneration: privacy.forwardingPrivacyGeneration), admitted(),
              case .accepted(let bootstrap) = await owner.relay.forwardingBootstrap(peer: context.peer,
                admission: admitted), admitted(),
              case .accepted(let value) = await owner.relay.forwardingEvidence(peer: context.peer,
                connectionID: context.connectionID, operation: .attach, admission: admitted,
                onSubmission: { owner.submitted = true }), admitted() else { return nil }
        sessions[context.connectionID] = Session(context: context, credential: bootstrap.credential)
        retained = true
        observe(value)
        return try? AudioForwardingBootstrap(credential: bootstrap.credential,
            ownCursor: bootstrap.ownCursor, snapshot: value)
    }

    func evidenceWillChange() {
        evidenceRevision = UUID()
        if enrollments.values.contains(where: { $0.submitted }) { resetAfterUncertainEvidence() }
    }

    private func resetAfterUncertainEvidence() {
        guard running, !recoveryBlocked, relay !== retiredRelay else { return }
        retiredRelay = relay
        if recovering != nil {
            recoveryBlocked = true
            evidenceRevision = UUID()
            enrollments.removeAll()
            sessions.removeAll()
            retiringSessions.removeAll()
            invalidate()
            relay.lost()
            return
        }
        guard !recoveryNeeded else { return }
        recoveryContexts = sessions.values.map(\.context).filter { $0.connectionIsCurrent() }
        evidenceRevision = UUID()
        enrollments.removeAll()
        sessions.removeAll()
        retiringSessions.removeAll()
        recoveryNeeded = true
        invalidate()
        relay.lost()
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard running, recoveryNeeded, recovering == nil, !recoveryBlocked,
              privacy.forwardingIntentAllowed else { return }
        recoveryNeeded = false
        let previous = relay
        recovering = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recovering = nil }
            guard await previous.waitUntilExited(until: .now.advanced(by: .seconds(3))),
                  self.running, !Task.isCancelled else { self.recoveryBlocked = true; return }
            guard self.privacy.forwardingIntentAllowed else { self.recoveryNeeded = true; return }
            do {
                guard let factory = self.replacement else { self.recoveryBlocked = true; return }
                let next = try factory()
                self.relay = next
                guard await next.start(), self.running, !Task.isCancelled, self.privacy.forwardingIntentAllowed,
                      case .accepted = await next.forwardingConfigure(
                        privacyGeneration: self.privacy.forwardingPrivacyGeneration), self.privacy.forwardingIntentAllowed else {
                    next.lost(); self.recoveryBlocked = true; return
                }
                let contexts = self.recoveryContexts
                self.recoveryContexts.removeAll()
                for context in contexts where context.connectionIsCurrent() {
                    let renewed = AudioForwardingConnectionContext(peer: context.peer, principal: context.principal,
                        role: context.role, connectionID: context.connectionID,
                        connectionIsCurrent: context.connectionIsCurrent, isCurrent: context.connectionIsCurrent)
                    _ = await self.enroll(renewed)
                }
            } catch {
                self.recoveryBlocked = true
            }
            if self.recoveryBlocked {
                print("연결 증거를 다시 확인하지 못해 원격 음성을 차단했습니다. 저장된 페어링과 음성 선택은 유지합니다.")
            }
        }
    }

    func disconnected(_ connectionID: UUID) {
        if let enrollment = enrollments.removeValue(forKey: connectionID), enrollment.submitted {
            resetAfterUncertainEvidence()
        }
        guard let session = sessions.removeValue(forKey: connectionID) else { return }
        if (active?.binding.pairedDeviceId ?? preparingBinding?.pairedDeviceId) == session.context.peer.id,
           !sessions.values.contains(where: { $0.context.peer.id == session.context.peer.id && $0.context.connectionIsCurrent() }) {
            invalidate()
        }
        retiringSessions[connectionID] = session
        Task { @MainActor [weak self] in await self?.retireEvidence(session) }
    }

    private func retireEvidence(_ session: Session) async {
        let id = session.context.connectionID, previous = relay
        let result = await previous.forwardingEvidence(peer: session.context.peer, connectionID: id, operation: .detach)
        guard retiringSessions[id]?.generation == session.generation else { return }
        if case .accepted = result { retiringSessions.removeValue(forKey: id) }
        else if running, relay === previous { resetAfterUncertainEvidence() }
    }

    func allows(_ fingerprint: Data, direction: PrivacyAudioScope) -> Bool {
        guard running, let active, active.binding.pairedDeviceId == AudioForwardingDeviceID(fingerprint: fingerprint),
              sessions.values.contains(where: {
                  $0.context.peer.id == active.binding.pairedDeviceId && $0.context.connectionIsCurrent()
              }) else { return false }
        switch direction {
        case .input: return coordinator.allowsInput(active, transport: .native)
        case .output: return coordinator.allowsOutput(active, transport: .native)
        }
    }

    private func refresh() async {
        scheduleRecovery()
        guard running, recovering == nil, !recoveryNeeded, !recoveryBlocked, privacy.forwardingIntentAllowed else { return }
        let generation = evidenceRevision
        for session in Array(retiringSessions.values) {
            await retireEvidence(session)
            guard running, evidenceRevision == generation, privacy.forwardingIntentAllowed else { return }
        }
        for (id, session) in Array(sessions) {
            guard session.context.connectionIsCurrent() else { disconnected(id); continue }
            let result = await relay.forwardingEvidence(peer: session.context.peer,
                connectionID: id, operation: .renew, admission: { [weak self] in
                    guard let self else { return false }
                    return self.running && self.privacy.forwardingIntentAllowed && self.evidenceRevision == generation &&
                        self.sessions[id]?.generation == session.generation && session.context.connectionIsCurrent()
                })
            guard running, privacy.forwardingIntentAllowed, evidenceRevision == generation else { return }
            guard sessions[id]?.generation == session.generation else { continue }
            guard case .accepted(let value) = result else {
                if result == nil { resetAfterUncertainEvidence(); return }
                disconnected(id); continue
            }
            observe(value)
        }
        guard running, privacy.forwardingIntentAllowed, evidenceRevision == generation else { return }
        guard let value = await readSnapshot() else { resetAfterUncertainEvidence(); return }
        guard running, privacy.forwardingIntentAllowed, evidenceRevision == generation else { return }
        observe(value)
    }

    private func readSnapshot() async -> AudioForwardingSnapshot? {
        guard running, case .accepted(let value) = await relay.forwardingSnapshot() else { return nil }
        return value
    }

    func providerSession(_ context: AudioForwardingConnectionContext) async -> ProviderCallSession? {
        guard context.role == .viewer, context.isCurrent(), let session = sessions[context.connectionID],
              session.context.peer.id == context.peer.id,
              session.context.peer.pairingGeneration == context.peer.pairingGeneration else { return nil }
        let owner = relay, evidence = evidenceRevision
        let admitted = { [weak self] in
            guard let self, !Task.isCancelled, self.running, self.recovering == nil,
                  !self.recoveryNeeded, !self.recoveryBlocked, self.relay === owner,
                  self.evidenceRevision == evidence, context.isCurrent(), self.privacy.forwardingIntentAllowed,
                  let latest = self.sessions[context.connectionID] else { return false }
            return latest.context.peer.id == context.peer.id &&
                latest.context.peer.pairingGeneration == context.peer.pairingGeneration &&
                latest.credential.credential == session.credential.credential &&
                latest.credential.pairingGeneration == session.credential.pairingGeneration
        }
        guard admitted(), let value = await readSnapshot(), admitted() else { return nil }
        return ProviderCallSession(relay: owner, peer: context.peer, credential: session.credential,
            snapshot: value, admitted: admitted, readSnapshot: { [weak self] in
                guard admitted(), let self, let latest = await self.readSnapshot(), admitted() else { return nil }
                return latest
            })
    }

    private func observe(_ value: AudioForwardingSnapshot) {
        guard running else { return }
        snapshot = value
        if let active, active.matches(value, committed: true), coordinator.isCurrent(active) { return }
        guard privacy.forwardingIntentAllowed, let scope = AudioForwardingCoordinator.Scope(value) else {
            if active != nil { invalidate() }
            return
        }
        guard preparing != scope.binding.bindingEpoch else { return }
        invalidate()
        if !privacy.latched { _ = privacy.armAndVerify() }
        _ = sentry.activate()
        let generation = revision
        preparing = scope.binding.bindingEpoch
        preparingBinding = scope.binding
        preparation = Task { @MainActor [weak self] in
            guard let self, self.running, generation == self.revision,
                  let latest = await self.readSnapshot(), scope.matches(latest) else { return }
            let outcome = await self.coordinator.reconcile(latest)
            guard self.running, generation == self.revision, !Task.isCancelled else { return }
            self.preparation = nil
            switch outcome {
            case .committed(let committed, let result):
                self.active = committed
                self.snapshot = result
                self.commitMedia(committed)
            case .blocked, .waiting:
                self.active = nil
                self.commitMedia(nil)
            }
        }
    }

    func invalidate() {
        let binding = active?.binding ?? preparingBinding
        revision = UUID()
        preparation?.cancel()
        preparation = nil
        preparing = nil
        preparingBinding = nil
        active = nil
        coordinator.invalidate()
        protection.invalidate()
        participants.invalidate()
        fenceMedia()
        commitMedia(nil)
        if let binding {
            Task { @MainActor [relay] in _ = await relay.forwardingDisconnect(binding) }
        }
    }

    func returnToLocal(admission: @escaping @MainActor () -> Bool) async -> Bool {
        guard running, recovering == nil, !recoveryNeeded, !recoveryBlocked, admission() else { return false }
        evidenceWillChange()
        guard !recoveryNeeded, recovering == nil, admission() else { return false }
        for (id, session) in sessions { retiringSessions[id] = session }
        sessions.removeAll()
        for session in Array(retiringSessions.values) {
            guard admission(), case .accepted = await relay.forwardingEvidence(peer: session.context.peer,
                connectionID: session.context.connectionID, operation: .detach, admission: admission),
                admission() else { return false }
            if retiringSessions[session.context.connectionID]?.generation == session.generation {
                retiringSessions.removeValue(forKey: session.context.connectionID)
            }
        }
        guard let current = await readSnapshot(), admission(),
              case .accepted(let cleared) = await relay.forwardingLocalReturn(
                expectedRevision: current.revision, admission: admission), admission(),
              cleared.intent == nil, cleared.binding == nil else { return false }
        snapshot = cleared
        invalidate()
        return true
    }

    func stop() {
        running = false
        polling?.cancel()
        polling = nil
        recovering?.cancel()
        recovering = nil
        enrollments.removeAll()
        evidenceRevision = UUID()
        invalidate()
        sessions.removeAll()
        retiringSessions.removeAll()
        relay.lost()
    }
}
