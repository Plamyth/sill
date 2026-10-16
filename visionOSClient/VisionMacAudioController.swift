import Foundation
import Combine
import StreamProtocol

struct VisionMacAudioDraft {
    let scope: VisionMacAudioScope
    let token: MacAudioRouteSession.CatalogToken
    let endpoints: [AudioRouteEndpoint]
    var inputUID: String?
    var outputUID: String?
}

/// Main-thread owner of native presentation and the shared session.
final class VisionMacAudioController: ObservableObject {
    @Published private(set) var model = MacAudioRouteSession()
    @Published private(set) var scope: VisionMacAudioScope?
    @Published private(set) var problem: String?
    @Published private(set) var catalogInvalid = false
    private let transport: VisionMacAudioTransport
    private let authorize: (VisionMacAudioScope) -> Bool
    private let clock: () -> Double
    private var timeout: DispatchWorkItem?
    private var deadline: Double?
    private var lastFetch = -Double.infinity
    private var offered = false
    private let statusWriter = VisionMacAudioStatusWriter()
    private(set) var owningWindow = false
    private var foreground = false
    private var trustedCurrentPeer = false
    private var selectionRequestCount = 0
    static let responseTimeout = 8.0

    init(transport: VisionMacAudioTransport, authorize: @escaping (VisionMacAudioScope) -> Bool,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.authorize = authorize
        self.clock = clock
        reportStatus()
    }

    deinit { timeout?.cancel() }

    func setScope(_ next: VisionMacAudioScope?, trustedCurrentPeer: Bool, owningWindow: Bool, foreground: Bool) {
        precondition(Thread.isMainThread)
        self.trustedCurrentPeer = trustedCurrentPeer
        self.owningWindow = owningWindow
        self.foreground = foreground
        defer { reportStatus() }
        guard next != scope else { return }
        cancelPending()
        model.bind(nil)
        problem = nil
        catalogInvalid = false
        scope = next
        lastFetch = -Double.infinity
        if let next, let peer = transport.peer(for: next) {
            model.bind(ObjectIdentifier(peer))
            refresh()
        }
    }

    var draft: VisionMacAudioDraft? {
        guard !catalogInvalid, let scope, let token = model.catalogToken, let state = model.state else { return nil }
        return VisionMacAudioDraft(scope: scope, token: token, endpoints: state.endpoints)
    }

    func canApply(_ draft: VisionMacAudioDraft) -> Bool {
        !catalogInvalid && scope == draft.scope && model.pending == nil &&
        model.catalogToken == draft.token && (draft.inputUID != nil || draft.outputUID != nil)
    }

    func isCurrent(_ draft: VisionMacAudioDraft) -> Bool {
        !catalogInvalid && scope == draft.scope && model.catalogToken == draft.token
    }

    func takeOffer() -> Bool {
        precondition(Thread.isMainThread)
        guard !offered, let scope, authorize(scope), draft != nil else { return false }
        offered = true
        return true
    }

    var canRefresh: Bool { scope != nil && model.pending == nil }

    func refresh() {
        precondition(Thread.isMainThread)
        let now = clock()
        guard canRefresh, let scope, authorize(scope), now.isFinite, now - lastFetch >= 1 else { return }
        lastFetch = now
        _ = transport.fetch(in: scope)
    }

    func apply(_ draft: VisionMacAudioDraft) {
        precondition(Thread.isMainThread)
        defer { reportStatus() }
        let now = clock()
        guard let scope, authorize(scope), self.scope == draft.scope, !catalogInvalid,
              let peer = model.peer, now.isFinite else { return }
        let request: AudioRouteSelection
        do {
            request = try model.request(displayed: draft.token, inputUID: draft.inputUID, outputUID: draft.outputUID)
        } catch {
            problem = error.localizedDescription
            return
        }
        problem = nil
        selectionRequestCount += 1
        deadline = now + Self.responseTimeout
        let id = request.requestID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.scope == scope, self.model.pending?.requestID == id else { return }
            self.expireIfNeeded()
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseTimeout, execute: item)
        let accepted = transport.change(request, in: scope) { [weak self] requestID in
            guard let self, self.scope == scope, self.model.pending?.requestID == requestID else { return }
            self.model.expire(requestID, on: peer)
            self.finish(requestID)
            self.reportStatus()
        }
        if !accepted {
            model.expire(id, on: peer)
            finish(id)
        }
    }

    func receive(_ data: Data, scope incoming: VisionMacAudioScope) {
        precondition(Thread.isMainThread)
        defer { reportStatus() }
        guard scope == incoming, authorize(incoming), let peer = model.peer else { return }
        expirePendingIfDue()
        guard data.count <= AudioRoutingPolicy.maxStatePayload,
              let state = Wire.decode(AudioRouteState.self, from: data) else { catalogInvalid = true; return }
        var next = model
        next.receive(state, from: peer)
        // Shared validation can refuse a decoded state without replacing its previous catalog.
        guard next.state == state else { catalogInvalid = true; return }
        catalogInvalid = false
        let requestID = model.pending?.requestID
        model = next
        if let requestID, model.pending == nil { finish(requestID) }
    }

    func closeChooser(expectedScope: VisionMacAudioScope?) {
        precondition(Thread.isMainThread)
        guard let expectedScope, scope == expectedScope else { return }
        cancelPending()
        reportStatus()
    }

    private func cancelPending() {
        if let pending = model.pending, let peer = model.peer {
            model.expire(pending.requestID, on: peer)
            finish(pending.requestID)
        }
    }

    func expireIfNeeded() {
        precondition(Thread.isMainThread)
        expirePendingIfDue()
        reportStatus()
    }

    private func expirePendingIfDue() {
        guard let deadline, clock() >= deadline, let pending = model.pending, let peer = model.peer else { return }
        model.expire(pending.requestID, on: peer)
        finish(pending.requestID)
    }

    private func finish(_ id: UUID) {
        timeout?.cancel()
        timeout = nil
        deadline = nil
        transport.finish(id)
    }

    var status: VisionMacAudioStatus {
        let valid = model.state != nil && !catalogInvalid
        let state = valid ? model.state : nil
        let outcome: VisionMacAudioStatus.Outcome
        if scope == nil { outcome = .inactive }
        else if catalogInvalid { outcome = .invalidCatalog }
        else if problem != nil { outcome = .localRefusal }
        else if let result = model.outcome {
            switch result {
            case .waiting: outcome = .waiting
            case .unverified: outcome = .unverified
            case .timedOut: outcome = .timedOut
            case .answered(let answer): outcome = VisionMacAudioStatus.Outcome(rawValue: answer.rawValue) ?? .unverified
            }
        } else if let state { outcome = state.available ? .ready : .unavailable }
        else { outcome = .awaitingCatalog }
        return VisionMacAudioStatus(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            trustedCurrentPeer: trustedCurrentPeer, owningWindow: owningWindow, foreground: foreground,
            catalogAvailable: state?.available == true, catalogValid: valid, catalogCount: state?.endpoints.count ?? 0,
            currentInputKnown: state?.available == true && state?.defaults.inputUID != nil,
            currentOutputKnown: state?.available == true && state?.defaults.outputUID != nil,
            pending: model.pending != nil, outcome: outcome, selectionRequestCount: selectionRequestCount)
    }

    private func reportStatus() { statusWriter.write(status) }
}
