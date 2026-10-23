import Foundation

// A single physical graph has a single logical owner, even across different Macs.
struct VisionRemoteAudioAuthority {
    typealias Intent = VisionRemoteAudioIntent
    struct Ticket: Equatable {
        let owner: UUID
        let epoch: UUID
        let request: Intent.Request
    }
    private struct Attempt: Hashable {
        let scope: Intent.Scope
        let direction: Intent.Direction
    }
    private(set) var intent: Intent
    private(set) var contexts: [UUID: Intent.Context] = [:]
    private(set) var owner: UUID?
    private(set) var epoch = UUID()
    private(set) var retiring: UUID?
    private var preferred: UUID?
    private var ownerScope: Intent.Scope?
    private var attempted: Set<Attempt> = []
    private var freshCatalog = false

    init(intent: Intent = Intent()) { self.intent = intent }

    mutating func update(_ id: UUID, context: Intent.Context?) {
        contexts[id] = context
    }

    mutating func setDesired(_ enabled: Bool, direction: Intent.Direction, hostKey: String, preferred id: UUID) {
        intent.setDesired(enabled, direction: direction, hostKey: hostKey)
        if enabled, contexts[id]?.admitted == true { preferred = id }
    }

    private func eligible(_ id: UUID) -> Bool {
        guard let context = contexts[id], context.admitted else { return false }
        return Intent.Direction.allCases.contains { intent.desired($0, hostKey: context.hostKey) }
    }

    // Return the old owner for synchronous revocation. Election is a separate call after cleanup.
    mutating func advance(cleanupReady: Bool) -> UUID? {
        if let owner, !eligible(owner) || contexts[owner]?.scope != ownerScope ||
            (preferred != nil && preferred != owner && eligible(preferred!)) {
            self.owner = nil
            retiring = owner
            epoch = UUID()
            freshCatalog = false
            attempted.removeAll()
            return owner
        }
        guard owner == nil, cleanupReady else { return nil }
        retiring = nil
        let candidate = preferred.flatMap { eligible($0) ? $0 : nil } ??
            contexts.keys.sorted { $0.uuidString < $1.uuidString }.first { eligible($0) }
        guard let candidate else { return nil }
        owner = candidate
        freshCatalog = false
        ownerScope = contexts[candidate]?.scope
        epoch = UUID()
        preferred = nil
        attempted.removeAll()
        return nil
    }

    mutating func invalidateCatalog(_ id: UUID) {
        guard owner == id else { return }
        freshCatalog = false
        attempted.removeAll()
    }

    mutating func observedCatalog(_ id: UUID, epoch: UUID, scope: Intent.Scope) {
        guard owner == id, self.epoch == epoch, ownerScope == scope,
              contexts[id]?.scope == scope, contexts[id]?.eligible == true else { return }
        freshCatalog = true
    }

    mutating func request(_ id: UUID, direction: Intent.Direction, manual: Bool = false) -> Ticket? {
        guard owner == id, freshCatalog, let context = contexts[id], context.eligible,
              let key = context.hostKey, let scope = context.scope,
              intent.desired(direction, hostKey: key),
              direction == .playback ? context.playbackAvailable :
                (context.microphoneAvailable && (manual || context.recordPermissionGranted)) else { return nil }
        let attempt = Attempt(scope: scope, direction: direction)
        if !manual, attempted.contains(attempt) { return nil }
        attempted.insert(attempt)
        return Ticket(owner: id, epoch: epoch, request: .init(hostKey: key, scope: scope,
            direction: direction, revision: intent.desiredRevision(direction, hostKey: key)))
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        guard owner == ticket.owner, epoch == ticket.epoch, freshCatalog,
              let context = contexts[ticket.owner] else { return false }
        return intent.isCurrent(ticket.request, context: context)
    }

    func permits(_ id: UUID, direction: Intent.Direction) -> Bool {
        guard owner == id, freshCatalog, let context = contexts[id], context.eligible,
              context.scope == ownerScope else { return false }
        return intent.desired(direction, hostKey: context.hostKey)
    }
}

#if os(visionOS)
import StreamProtocol

final class VisionRemoteAudioStore {
    static let shared = VisionRemoteAudioStore()
    static let changed = Notification.Name("VisionRemoteAudioAuthority.changed")
    private final class Client {
        weak var value: StreamClient?
        init(_ value: StreamClient) { self.value = value }
    }
    private(set) var model: VisionRemoteAudioAuthority
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        model = VisionRemoteAudioAuthority(intent: .load(defaults))
    }
    private var clients: [UUID: Client] = [:]
    private var refreshing = false
    private var permissionOwner: UUID?
    private var pendingNativeSelection: UUID?
    private struct CatalogRefresh {
        let requestID: UUID
        let owner: UUID
        let epoch: UUID
        let scope: VisionRemoteAudioIntent.Scope
        let peer: ObjectIdentifier
    }
    private var catalogEpoch: UUID?
    private var pendingCatalog: CatalogRefresh?
    private var pendingManual: [VisionRemoteAudioIntent.Direction: (VisionRemoteAudioAuthority.Ticket, VisionAudioScope?)] = [:]

    func beginPermission(_ id: UUID) -> Bool {
        guard permissionOwner == nil else { return false }
        permissionOwner = id
        return true
    }

    func endPermission(_ id: UUID) {
        if permissionOwner == id { permissionOwner = nil }
        refresh()
    }

    func register(_ client: StreamClient) {
        clients[client.visionAudioOwnerID] = Client(client)
    }

    func retire(_ client: StreamClient) {
        revokeActual(client)
        clients.removeValue(forKey: client.visionAudioOwnerID)
        model.update(client.visionAudioOwnerID, context: nil)
        refresh()
    }

    func permits(_ client: StreamClient, direction: VisionRemoteAudioIntent.Direction) -> Bool {
        model.permits(client.visionAudioOwnerID, direction: direction) && client.visionAudioIntentContext.eligible &&
            client.visionForwarding?.permits(direction) == true
    }

    @discardableResult
    func setDesired(_ enabled: Bool, client: StreamClient, direction: VisionRemoteAudioIntent.Direction,
                    expectedScope: VisionAudioScope?) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let key = client.visionAudioTrustedHostKey else {
            if !enabled { stop(client, direction: direction) }
            return !enabled
        }
        model.update(client.visionAudioOwnerID, context: client.visionAudioIntentContext)
        model.setDesired(enabled, direction: direction, hostKey: key, preferred: client.visionAudioOwnerID)
        model.intent.persist(defaults)
        if !enabled {
            // Notification delivery is not the STOP barrier. Revoke all matching clients here.
            for entry in clients.values {
                if let value = entry.value, value.visionAudioTrustedHostKey == key { stop(value, direction: direction) }
            }
        }
        revokeActual(client)
        pendingNativeSelection = client.visionAudioOwnerID
        let admitted = refresh(manual: enabled ? (client.visionAudioOwnerID, direction, expectedScope) : nil)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return !enabled || admitted || client.visionAudioIntentContext.admitted
    }

    private func stop(_ client: StreamClient, direction: VisionRemoteAudioIntent.Direction) {
        if direction == .playback { client.visionAudio.stop() }
        else { client.stopVisionMicrophoneActual() }
    }

    private func revokeActual(_ client: StreamClient) {
        // Both roles must be revoked before either close rebuilds the shared graph.
        client.suspendVisionForwarding()
        VisionAudioSharedHardware.shared.revoke(owner: client.visionAudioOwnerID)
        client.visionAudio.stop()
        client.stopVisionMicrophoneActual()
    }

    func withdrawPrivacy(_ source: StreamClient) {
        guard let key = source.visionAudioTrustedHostKey else {
            revokeActual(source)
            refresh()
            return
        }
        for entry in clients.values {
            guard let client = entry.value, client.visionAudioTrustedHostKey == key else { continue }
            client.visionAudioPrivacyBlocked = true
            revokeActual(client)
        }
        refresh()
    }

    func invalidateNativeCatalog(_ client: StreamClient) {
        guard model.owner == client.visionAudioOwnerID else { return }
        model.invalidateCatalog(client.visionAudioOwnerID)
        catalogEpoch = nil
        pendingCatalog = nil
    }

    func observedCatalog(_ client: StreamClient, list: WindowList, peer: ObjectIdentifier) {
        guard let pending = pendingCatalog, list.responseRequestID == pending.requestID,
              pending.peer == peer, pending.owner == client.visionAudioOwnerID,
              client.visionAudioCatalogPeer == peer, model.owner == pending.owner,
              model.epoch == pending.epoch, client.visionAudioIntentContext.scope == pending.scope else { return }
        pendingCatalog = nil
        model.update(pending.owner, context: client.visionAudioIntentContext)
        model.observedCatalog(pending.owner, epoch: pending.epoch, scope: pending.scope)
    }

    @discardableResult
    func refresh(manual: (UUID, VisionRemoteAudioIntent.Direction, VisionAudioScope?)? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !refreshing else { return false }
        refreshing = true
        defer { refreshing = false }
        for (id, entry) in clients {
            model.update(id, context: entry.value?.visionAudioIntentContext)
        }
        let previousOwner = model.owner
        // Cancelled OS permission requests retain their slot until their original callback drains.
        func cleanupReady() -> Bool {
            VisionAudioSharedHardware.shared.isIdle && permissionOwner == nil &&
                clients.values.allSatisfy { $0.value?.microphoneAuthorization == nil }
        }
        if let revoked = model.advance(cleanupReady: cleanupReady()), let old = clients[revoked]?.value {
            revokeActual(old)
        }
        _ = model.advance(cleanupReady: cleanupReady())
        if previousOwner != model.owner {
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        if catalogEpoch != model.epoch {
            pendingCatalog = nil
            pendingManual = pendingManual.compactMapValues { saved in
                let ticket = saved.0
                guard model.owner == ticket.owner, let context = model.contexts[ticket.owner],
                      let scope = context.scope, context.hostKey == ticket.request.hostKey,
                      scope.connection == ticket.request.scope.connection,
                      scope.window == ticket.request.scope.window, scope.admission == ticket.request.scope.admission,
                      scope.video == ticket.request.scope.video, scope.foreground == ticket.request.scope.foreground,
                      model.intent.desiredRevision(ticket.request.direction, hostKey: ticket.request.hostKey) == ticket.request.revision else { return nil }
                return (.init(owner: ticket.owner, epoch: model.epoch,
                    request: .init(hostKey: ticket.request.hostKey, scope: scope, direction: ticket.request.direction,
                                   revision: ticket.request.revision)), saved.1)
            }
        }
        if let selected = pendingNativeSelection.flatMap({ clients[$0]?.value }),
           !selected.visionPlaybackDesired && !selected.visionMicrophoneDesired {
            pendingNativeSelection = nil
            selected.reconcileVisionForwarding(manual: true)
        }
        guard let owner = model.owner, let client = clients[owner]?.value else { return false }
        let nativeManual = pendingNativeSelection.flatMap { clients[$0]?.value }?.visionAudioTrustedHostKey == client.visionAudioTrustedHostKey
        if nativeManual { pendingNativeSelection = nil }
        client.reconcileVisionForwarding(manual: nativeManual)
        if catalogEpoch != model.epoch, client.visionAudioIntentContext.eligible {
            catalogEpoch = model.epoch
            if client.visionAudioIntentCatalog?.catalogRefresh == 1,
               let peer = client.visionAudioCatalogPeer, let scope = client.visionAudioIntentContext.scope {
                let pending = CatalogRefresh(requestID: UUID(), owner: owner, epoch: model.epoch, scope: scope, peer: peer)
                pendingCatalog = pending
                client.requestVisionAudioCatalog(pending.requestID, scope: scope)
            }
        }
        if let manual, manual.0 == owner, let context = model.contexts[owner],
           let key = context.hostKey, let scope = context.scope {
            pendingManual[manual.1] = (.init(owner: owner, epoch: model.epoch,
                request: .init(hostKey: key, scope: scope, direction: manual.1,
                    revision: model.intent.desiredRevision(manual.1, hostKey: key))), manual.2)
        }
        var admitted = false
        for direction in VisionRemoteAudioIntent.Direction.allCases {
            let savedManual = pendingManual[direction]
            let isManual = savedManual.map { model.isCurrent($0.0) } == true
            guard let ticket = model.request(owner, direction: direction, manual: isManual),
                  model.isCurrent(ticket), client.visionAudioIntentContext.eligible else { continue }
            pendingManual.removeValue(forKey: direction)
            if direction == .playback {
                let enabled = client.visionAudio.enable(expectedScope: isManual ? savedManual?.1 : nil)
                if isManual { admitted = enabled }
            } else if isManual { client.toggleVisionMicrophone(); admitted = true }
            else { client.startVisionMicrophoneAutomatically() }
        }
        return admitted || (manual?.0 == owner && pendingCatalog != nil)
    }
}
#endif
