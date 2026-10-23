import Foundation
import StreamProtocol

/// The common owner lease is independent of the legacy microphone/playback grants.
/// All time arguments are monotonic seconds supplied by the caller.
struct IPadAudioForwarding {
    struct Context: Equatable {
        let peer: ObjectIdentifier
        let mac: IPadDesiredAudio.Identity
        let device: AudioForwardingDeviceID
        let source: StreamSource
        let generation: UUID
        let videoEpoch: UUID
        let lifecycle: UUID
    }
    struct Durable: Codable, Equatable {
        let device: AudioForwardingDeviceID
        let intentID: UUID
        let revision: AudioForwardingRevision
        let generation: UUID
        let selection: IPadDesiredAudio.Selection
    }
    enum Phase: Equatable { case unknown, observing, ready, submitting, quiescing, active, blocked }
    private struct Pending {
        let control: AudioForwardingControl
        let context: Context
        let sentAt: TimeInterval
    }
    private(set) var context: Context?
    private(set) var durable: Durable?
    private(set) var phase = Phase.unknown
    private(set) var catalog: AudioForwardingCatalog?
    private(set) var snapshot: AudioForwardingSnapshot?
    private(set) var binding: AudioForwardingBinding?
    private var cursor: AudioForwardingBootstrap.OwnCursor?
    private var pending: Pending?
    private var draft: IPadDesiredAudio.Selection?
    private var nextPoll: TimeInterval?
    private var freshUntil: TimeInterval?
    private var lastTime: TimeInterval?
    private var quiescingUntil: TimeInterval?
    private var transport = UUID()
    private var resumeAllowed = true
    private var desired = IPadDesiredAudio.Selection()
    var pendingRequestID: UUID? { pending?.control.requestID }
    var mediaDeadline: TimeInterval? { phase == .active ? freshUntil : nil }
    var supported: Bool { catalog != nil && context != nil }
    var wakeAt: TimeInterval? {
        [pending.map { $0.sentAt + 10 }, nextPoll, freshUntil, quiescingUntil].compactMap { $0 }.min()
    }

    mutating func connect(_ next: Context?, durable saved: Durable?, desired: IPadDesiredAudio.Selection = .init(), observeImmediately: Bool = true, now: TimeInterval) -> AudioForwardingControl? {
        guard next != context else { return nil }
        self = Self()
        context = next
        durable = saved
        self.desired = desired
        resumeAllowed = saved?.selection == desired
        guard next != nil else { return nil }
        return observeImmediately ? observe(now: now) : nil
    }

    mutating func begin(now: TimeInterval) -> AudioForwardingControl? {
        guard phase == .unknown, context != nil, pending == nil else { return nil }
        return observe(now: now)
    }

    mutating func markSent(_ requestID: UUID, now: TimeInterval) -> Bool {
        guard checkTime(now), let pending, pending.control.requestID == requestID else { return false }
        self.pending = Pending(control: pending.control, context: pending.context, sentAt: now)
        return true
    }

    mutating func block() {
        phase = .blocked
        pending = nil; draft = nil; nextPoll = nil; freshUntil = nil; quiescingUntil = nil
        binding = nil; resumeAllowed = false
    }

    private mutating func checkTime(_ now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { block(); return false }
        lastTime = now
        return true
    }

    private mutating func observe(now: TimeInterval) -> AudioForwardingControl? {
        guard checkTime(now), let context, pending == nil else { return nil }
        let control = try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil)
        pending = Pending(control: control, context: context, sentAt: now)
        if phase == .unknown || phase == .blocked { phase = .observing }
        nextPoll = nil
        return control
    }

    /// Explicit selection may wait for its initial observe, but never crosses a local scope change.
    mutating func select(_ selection: IPadDesiredAudio.Selection, in expected: Context,
                         now: TimeInterval, deferToTransport: Bool = false) -> AudioForwardingControl? {
        guard checkTime(now), context == expected else { return nil }
        draft = selection
        desired = selection
        freshUntil = nil
        if phase == .blocked {
            catalog = nil; cursor = nil; snapshot = nil; phase = .unknown
        }
        if catalog == nil { return deferToTransport || pending != nil ? nil : observe(now: now) }
        if pending != nil { return nil }
        return submit(selection, automatic: false, now: now)
    }

    private mutating func submit(_ selection: IPadDesiredAudio.Selection, automatic: Bool,
                                 now: TimeInterval) -> AudioForwardingControl? {
        guard let context, let cursor, let snapshot, catalog != nil,
              pending == nil, (automatic || cursor.intentRevision.value < UInt64.max),
              cursor.bindingRevision.value < UInt64.max else { block(); return nil }
        let own = snapshot.intent
        let owns = own?.pairedDeviceId == context.device
        let same = own?.pairedDeviceId == context.device && own?.intentId == durable?.intentID &&
            own?.intentGeneration == durable?.generation && own?.intentRevision == durable?.revision &&
            own?.inputDesired == durable?.selection.microphone && own?.outputDesired == durable?.selection.playback
        if automatic && (!resumeAllowed || !same || durable?.device != context.device ||
                         durable?.selection != selection || desired != selection || (!selection.microphone && !selection.playback)) {
            return nil
        }
        let action: AudioForwardingIntentRequest.Action
        if !selection.microphone && !selection.playback {
            guard owns else { draft = nil; phase = .ready; return nil }
            action = .stop
        } else { action = automatic ? .resume : (owns ? .update : .request) }
        guard let request = try? AudioForwardingIntentRequest(pairedDeviceId: context.device,
            intentId: owns ? own!.intentId : UUID(), intentRevision: automatic ? durable!.revision : .init(cursor.intentRevision.value + 1),
            action: action, inputDesired: selection.microphone, outputDesired: selection.playback,
            expectedRevision: snapshot.revision, transportId: transport, transportKind: .native,
            bindingRevision: .init(cursor.bindingRevision.value + 1)),
              let control = try? AudioForwardingControl(requestID: UUID(), operation: .submit, intent: request) else {
            block(); return nil
        }
        pending = Pending(control: control, context: context, sentAt: now)
        draft = nil; phase = .submitting; freshUntil = nil; binding = nil; nextPoll = nil
        return control
    }

    mutating func advance(now: TimeInterval) -> AudioForwardingControl? {
        guard checkTime(now) else { return nil }
        if let freshUntil, now >= freshUntil { block(); return nil }
        if let quiescingUntil, now >= quiescingUntil { block(); return nil }
        if let pending, now >= pending.sentAt + 10 { block(); return nil }
        guard let nextPoll, now >= nextPoll, pending == nil,
              phase == .active || phase == .quiescing else { return nil }
        return observe(now: now)
    }

    mutating func receive(_ state: AudioForwardingState, from expected: Context,
                          now: TimeInterval) -> AudioForwardingControl? {
        guard checkTime(now), context == expected else { return nil }
        guard let pending, pending.context == expected,
              pending.control.requestID == state.requestID, pending.control.operation == state.operation,
              now < pending.sentAt + 10 else { block(); return nil }
        if let freshUntil, now >= freshUntil { block(); return nil }
        self.pending = nil
        if state.operation == .observe {
            guard now < pending.sentAt + 3, let catalog = state.catalog,
                  catalog.principal.id == expected.device,
                  catalog.bootstrap.credential.pairedDeviceId == expected.device else { block(); return nil }
            if let previous = self.catalog {
                guard previous.principal.id == catalog.principal.id,
                      previous.principal.kind == catalog.principal.kind,
                      previous.principal.authorizationGeneration == catalog.principal.authorizationGeneration,
                      previous.bootstrap.credential.credential == catalog.bootstrap.credential.credential else { block(); return nil }
            }
            let incoming = catalog.bootstrap.snapshot
            if let snapshot, incoming.revision.value < snapshot.revision.value { block(); return nil }
            if binding != nil, let cursor,
               catalog.bootstrap.ownCursor.bindingRevision != cursor.bindingRevision { block(); return nil }
            self.catalog = catalog
            cursor = catalog.bootstrap.ownCursor
            snapshot = incoming
            if binding != nil {
                guard catalog.bootstrap.ownCursor.intentRevision == durable?.revision,
                      accept(incoming, sentAt: pending.sentAt, now: now, stable: true) else { block(); return nil }
            } else {
                phase = .ready
                if let draft { return submit(draft, automatic: false, now: now) }
                if let durable { return submit(durable.selection, automatic: true, now: now) }
            }
        } else {
            guard let result = state.result, let request = pending.control.intent else { block(); return nil }
            switch result {
            case .refused(_, let snapshot): self.snapshot = snapshot; block(); return nil
            case .accepted(let snapshot):
                guard let intent = snapshot.intent, intent.pairedDeviceId == request.pairedDeviceId,
                      intent.intentId == request.intentId, intent.intentRevision == request.intentRevision,
                      intent.inputDesired == request.inputDesired, intent.outputDesired == request.outputDesired,
                      snapshot.revision.value > request.expectedRevision.value,
                      let binding = snapshot.binding, binding.transportId == request.transportId,
                      binding.transportKind == .native else { block(); return nil }
                if request.action == .resume, intent.intentGeneration != durable?.generation { block(); return nil }
                durable = Durable(device: intent.pairedDeviceId, intentID: intent.intentId,
                    revision: intent.intentRevision, generation: intent.intentGeneration,
                    selection: .init(microphone: intent.inputDesired, playback: intent.outputDesired))
                cursor = .init(intentRevision: request.intentRevision, bindingRevision: request.bindingRevision)
                self.snapshot = snapshot
                guard now < pending.sentAt + 3,
                      accept(snapshot, sentAt: pending.sentAt, now: now, stable: false) else { block(); return nil }
            }
        }
        if let draft { return submit(draft, automatic: false, now: now) }
        return nil
    }

    private mutating func accept(_ snapshot: AudioForwardingSnapshot, sentAt: TimeInterval,
                                 now: TimeInterval, stable: Bool) -> Bool {
        guard let context, let durable, let intent = snapshot.intent, let next = snapshot.binding,
              intent.pairedDeviceId == context.device, intent.intentId == durable.intentID,
              intent.intentRevision == durable.revision, intent.intentGeneration == durable.generation,
              intent.inputDesired == durable.selection.microphone, intent.outputDesired == durable.selection.playback,
              next.pairedDeviceId == context.device, next.intentGeneration == durable.generation,
              next.transportKind == .native, next.transportId == transport else { return false }
        if stable, let old = binding {
            guard old.bindingEpoch == next.bindingEpoch, old.configuration == next.configuration,
                  old.operationId == next.operationId,
                  !(old.phase == .active && next.phase != .active) else { return false }
        }
        binding = next
        switch next.phase {
        case .active:
            guard durable.selection.microphone || durable.selection.playback else { return false }
            phase = .active; freshUntil = sentAt + 3; quiescingUntil = nil
        case .quiescing:
            phase = .quiescing; freshUntil = nil
            if quiescingUntil == nil { quiescingUntil = now + 10 }
        case .off:
            guard !durable.selection.microphone && !durable.selection.playback else { return false }
            phase = .ready; freshUntil = nil; nextPoll = nil; quiescingUntil = nil
            return true
        }
        nextPoll = max(now, sentAt + 1)
        return true
    }

    func permits(_ direction: IPadDesiredAudio.Direction, in expected: Context, now: TimeInterval) -> Bool {
        guard now.isFinite, lastTime.map({ now >= $0 }) ?? false,
              context == expected, phase == .active, let freshUntil, now < freshUntil,
              let durable, let binding, binding.phase == .active,
              binding.pairedDeviceId == expected.device, binding.transportId == transport,
              binding.intentGeneration == durable.generation else { return false }
        return durable.selection[direction]
    }
}
