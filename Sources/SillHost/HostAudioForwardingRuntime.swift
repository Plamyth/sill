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
    }
    private let relay: LocalAudioRelay
    private let privacy: HostAudioPrivacy
    private let sentry: HostSentry
    private let participants: AudioForwardingParticipants
    private let protection: AudioForwardingProtection
    private let fenceMedia: () -> Void
    private let commitMedia: (AudioForwardingCoordinator.Scope?) -> Void
    private var sessions: [UUID: Session] = [:]
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
         fenceMedia: @escaping () -> Void,
         commitMedia: @escaping (AudioForwardingCoordinator.Scope?) -> Void) {
        self.relay = relay
        self.privacy = privacy
        self.sentry = sentry
        self.fenceMedia = fenceMedia
        self.commitMedia = commitMedia
        participants = AudioForwardingParticipants(registry: privacy.participants)
        protection = AudioForwardingProtection(audio: privacy, sentry: sentry, configuration: {
            relay.forwardingConfiguration(privacyGeneration: privacy.forwardingPrivacyGeneration)
        })
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
        guard running, context.isCurrent(),
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
        guard context.isCurrent(), privacy.forwardingIntentAllowed else { return nil }
        if !privacy.latched {
            guard privacy.forwardingIntentAllowed else { return nil }
            _ = privacy.armAndVerify()
        }
        guard case .accepted = await relay.forwardingConfigure(
                privacyGeneration: privacy.forwardingPrivacyGeneration), context.isCurrent(),
              case .accepted(let bootstrap) = await relay.forwardingBootstrap(peer: context.peer,
                admission: context.isCurrent), context.isCurrent(),
              case .accepted(let value) = await relay.forwardingEvidence(peer: context.peer,
                connectionID: context.connectionID, operation: .attach, admission: context.isCurrent),
              context.isCurrent() else { return nil }
        sessions[context.connectionID] = Session(context: context, credential: bootstrap.credential)
        observe(value)
        return try? AudioForwardingBootstrap(credential: bootstrap.credential,
            ownCursor: bootstrap.ownCursor, snapshot: value)
    }

    func disconnected(_ connectionID: UUID) {
        guard let session = sessions.removeValue(forKey: connectionID) else { return }
        if (active?.binding.pairedDeviceId ?? preparingBinding?.pairedDeviceId) == session.context.peer.id,
           !sessions.values.contains(where: { $0.context.peer.id == session.context.peer.id && $0.context.connectionIsCurrent() }) {
            invalidate()
        }
        Task { @MainActor [relay] in
            _ = await relay.forwardingEvidence(peer: session.context.peer, connectionID: connectionID, operation: .detach)
        }
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
        guard running, privacy.forwardingIntentAllowed else { return }
        for (id, session) in Array(sessions) {
            guard session.context.connectionIsCurrent() else { disconnected(id); continue }
            guard case .accepted(let value) = await relay.forwardingEvidence(peer: session.context.peer,
                connectionID: id, operation: .renew, admission: session.context.connectionIsCurrent) else {
                disconnected(id)
                continue
            }
            observe(value)
        }
        guard let value = await readSnapshot() else { invalidate(); return }
        observe(value)
    }

    private func readSnapshot() async -> AudioForwardingSnapshot? {
        guard running, case .accepted(let value) = await relay.forwardingSnapshot() else { return nil }
        return value
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
        guard running, admission() else { return false }
        let retiring = Array(sessions.values)
        sessions.removeAll()
        for session in retiring {
            guard admission(), case .accepted = await relay.forwardingEvidence(peer: session.context.peer,
                connectionID: session.context.connectionID, operation: .detach, admission: admission),
                admission() else { return false }
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
        invalidate()
        sessions.removeAll()
        relay.lost()
    }
}
