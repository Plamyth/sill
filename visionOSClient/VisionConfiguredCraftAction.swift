import Foundation
import StreamProtocol

struct VisionConfiguredCraftAction {
    static let holdDuration = 0.5
    static let preparationBudget = 8.0
    static let responseBudget = 10.0

    struct Binding: Equatable {
        let deviceId: String
        let profileId: UUID
        let assignmentSha256: String
    }

    typealias Catalog = ConfiguredCraftActionCatalog
    typealias Request = ConfiguredCraftActionRequest
    typealias Result = ConfiguredCraftActionResult

    struct Fence: Equatable {
        let hostKey: String
        let connection: UUID
        let window: UUID
        let admission: UUID
        let video: UUID
        let foreground: UUID
        let binding: Binding
        let routeGeneration: UUID
        let selection: VisionRemoteAudioIntent.Desire?
        let selectionRevision: UInt64
        let otherDeviceSelected: Bool
        let deviceRouteRevision: UUID?
        func matchesMediaScope(_ scope: VisionRemoteAudioIntent.Scope?) -> Bool {
            guard let scope else { return false }
            return connection == scope.connection && window == scope.window && admission == scope.admission &&
                video == scope.video && foreground == scope.foreground
        }
    }
    struct MediaReadback: Equatable {
        let desire: VisionRemoteAudioIntent.Desire
        let microphoneReady: Bool
        let speakerReady: Bool
        let microphoneOff: Bool
        let speakerOff: Bool
    }

    struct Context: Equatable {
        var hostKey: String?
        var scope: VisionRemoteAudioIntent.Scope?
        var binding: Binding?
        var routeGeneration: UUID?
        var capabilityPresent = false
        var routeImplemented = false
        var admitted = false
        var invocationAllowed = true
        var selection: VisionRemoteAudioIntent.Desire?
        var selectionRevision: UInt64 = 0
        var otherDeviceSelected = false
        var deviceRouteRevision: UUID?
        var readback: MediaReadback?

        var mediaSelection: VisionRemoteAudioIntent.Desire {
            selection ?? (otherDeviceSelected ? .init() : .init(playback: true, microphone: true))
        }
        var mediaReady: Bool {
            let selected = mediaSelection
            guard let readback, readback.desire == selected else { return false }
            return (selected.microphone ? readback.microphoneReady : readback.microphoneOff) &&
                (selected.playback ? readback.speakerReady : readback.speakerOff)
        }

        var fence: Fence? {
            guard capabilityPresent, routeImplemented, admitted, invocationAllowed,
                  let hostKey, !hostKey.isEmpty, let scope, let binding, let routeGeneration,
                  !binding.deviceId.isEmpty, !binding.assignmentSha256.isEmpty,
                  !otherDeviceSelected || deviceRouteRevision != nil else { return nil }
            return .init(hostKey: hostKey, connection: scope.connection, window: scope.window,
                admission: scope.admission, video: scope.video, foreground: scope.foreground,
                binding: binding, routeGeneration: routeGeneration,
                selection: selection, selectionRevision: selectionRevision,
                otherDeviceSelected: otherDeviceSelected, deviceRouteRevision: deviceRouteRevision)
        }
    }

    struct Operation: Equatable {
        let request: Request
        let fence: Fence
        let mediaSelection: VisionRemoteAudioIntent.Desire
    }
    enum Phase: Equatable {
        case idle
        case preparing(Operation, since: Double, until: Double)
        case ready(Operation, since: Double, until: Double)
        case awaiting(Operation, since: Double, until: Double)
        case completed(Operation, Result)
        case cancelled(Operation)
        case unknown(Operation)
    }
    enum Effect: Equatable {
        case prepare(Operation)
        case invoke(Operation)
        case cancelPreparation(Operation)
    }
    private(set) var phase = Phase.idle
    var operation: Operation? {
        switch phase {
        case .idle: return nil
        case .preparing(let operation, _, _), .ready(let operation, _, _), .awaiting(let operation, _, _),
             .completed(let operation, _), .cancelled(let operation), .unknown(let operation): return operation
        }
    }

    func canBegin(_ context: Context) -> Bool {
        guard context.fence != nil else { return false }
        switch phase {
        case .idle, .cancelled, .unknown, .completed: return true
        case .preparing, .ready, .awaiting: return false
        }
    }

    mutating func begin(heldFor: Double, context: Context, now: Double, issuedAt: Date,
                        operationId: () -> UUID = UUID.init) -> Effect? {
        let epochMilliseconds = issuedAt.timeIntervalSince1970 * 1000
        guard heldFor.isFinite, heldFor >= Self.holdDuration, now.isFinite, now >= 0,
              epochMilliseconds.isFinite, epochMilliseconds >= 1, epochMilliseconds <= 9_007_199_254_740_991,
              canBegin(context), let fence = context.fence else { return nil }
        guard let device = AudioForwardingDeviceID(hex: fence.binding.deviceId),
              let catalog = try? Catalog(expectedProfileId: fence.binding.profileId,
                  expectedAssignmentSha256: fence.binding.assignmentSha256),
              let request = try? Request(operationId: operationId(), deviceId: device,
                  catalog: catalog, issuedAt: Int64(epochMilliseconds)) else { return nil }
        let operation = Operation(request: request, fence: fence, mediaSelection: context.mediaSelection)
        if context.mediaReady {
            phase = .ready(operation, since: now, until: now + Self.responseBudget)
            return .invoke(operation)
        }
        phase = .preparing(operation, since: now, until: now + Self.preparationBudget)
        return .prepare(operation)
    }

    @discardableResult
    mutating func recordPreparedSelection(operationId: UUID, revision: UInt64, context: Context) -> Bool {
        guard case .preparing(let operation, let since, let until) = phase,
              operation.request.operationId == operationId,
              context.selection == operation.mediaSelection, context.selectionRevision == revision,
              let current = context.fence else { return false }
        var previousSelection = context
        previousSelection.selection = operation.fence.selection
        previousSelection.selectionRevision = operation.fence.selectionRevision
        guard previousSelection.fence == operation.fence else { return false }
        phase = .preparing(.init(request: operation.request, fence: current, mediaSelection: operation.mediaSelection),
                           since: since, until: until)
        return true
    }

    mutating func advance(context: Context, now: Double) -> Effect? {
        switch phase {
        case .preparing(let operation, let since, let until):
            guard context.fence == operation.fence, now.isFinite, now >= since, now < until else {
                phase = .cancelled(operation)
                return .cancelPreparation(operation)
            }
            guard context.mediaReady else { return nil }
            phase = .ready(operation, since: now, until: now + Self.responseBudget)
            return .invoke(operation)
        case .ready(let operation, let since, let until):
            guard context.fence == operation.fence, context.mediaReady,
                  now.isFinite, now >= since, now < until else {
                phase = .cancelled(operation)
                return .cancelPreparation(operation)
            }
            return nil
        case .awaiting(let operation, let since, let until):
            guard context.fence == operation.fence, context.mediaReady, now.isFinite, now >= since, now < until else {
                phase = .unknown(operation)
                return .cancelPreparation(operation)
            }
            return nil
        default: return nil
        }
    }

    mutating func takeInvocation(_ operation: Operation, context: Context, now: Double) -> Request? {
        guard case .ready(let current, let since, let until) = phase, current == operation else { return nil }
        guard context.fence == current.fence, context.mediaReady,
              now.isFinite, now >= since, now < until else {
            phase = .cancelled(current)
            return nil
        }
        phase = .awaiting(current, since: now, until: now + Self.responseBudget)
        return current.request
    }

    @discardableResult
    mutating func cancel() -> Effect? {
        switch phase {
        case .preparing(let operation, _, _), .ready(let operation, _, _):
            phase = .cancelled(operation); return .cancelPreparation(operation)
        case .awaiting(let operation, _, _): phase = .unknown(operation); return .cancelPreparation(operation)
        default: return nil
        }
    }

    @discardableResult
    mutating func receive(_ result: Result, context: Context, now: Double) -> Bool {
        guard case .awaiting(let operation, let since, let until) = phase,
              context.fence == operation.fence, now.isFinite, now >= since, now < until,
              result.operationId == operation.request.operationId,
              result.deviceId == operation.request.deviceId,
              !result.effectConfirmed,
              result.outcome != .invoked || result.invoked,
              result.outcome != .rejected || !result.invoked else { return false }
        phase = .completed(operation, result)
        return true
    }

    var message: String? {
        switch phase {
        case .idle: return nil
        case .preparing: return "마이크·스피커를 준비하고 있습니다."
        case .ready: return "음성 명령 전송을 준비했습니다."
        case .awaiting: return "음성 명령의 호출 결과를 확인하고 있습니다."
        case .cancelled: return "음성 명령 준비를 취소했습니다."
        case .unknown: return "호출 결과를 확인하지 못했습니다. 자동으로 다시 실행하지 않습니다."
        case .completed(let operation, let result):
            switch result.outcome {
            case .invoked:
                return result.bindingSha256 == operation.request.expectedAssignmentSha256 ?
                    "음성 명령의 응답을 받았습니다. 실제 실행·대화 효과는 미확인입니다." :
                    "할당 확인 값이 달라 호출 효과는 미확인입니다."
            case .rejected: return "음성 명령이 거절됐습니다."
                case .unknown: return "호출 효과를 확인하지 못했습니다. 자동으로 다시 실행하지 않습니다."
            }
        }
    }

    mutating func receiveReadback(_ result: Result, hostKey: String, device: AudioForwardingDeviceID) -> Bool {
        guard let operation, operation.fence.hostKey == hostKey, operation.request.deviceId == device,
              result.deviceId == device, result.operationId == operation.request.operationId,
              !result.effectConfirmed, result.outcome != .invoked || result.invoked,
              result.outcome != .rejected || !result.invoked else { return false }
        switch phase {
        case .unknown: break
        case .completed(_, let old) where old.outcome == .unknown: break
        default: return false
        }
        phase = .completed(operation, result)
        return true
    }
}


import Combine

final class VisionConfiguredCraftActionExecutor: ObservableObject {
    typealias Action = VisionConfiguredCraftAction
    struct ReadScope: Equatable {
        let hostKey: String
        let connection: UUID
        let window: UUID
        let admission: UUID
        let foreground: UUID
        let video: UUID?
        let device: AudioForwardingDeviceID
    }
    private struct Pending {
        let control: ConfiguredCraftActionControl
        let scope: ReadScope
        let until: Double
        var submitted = false
    }
    @Published private(set) var model = Action()
    @Published private(set) var problem: String?
    private var capability = false
    private var scope: ReadScope?
    private var catalog: Action.Catalog?
    private var catalogRevision: UUID?
    private var catalogAttempted = false
    private var pending: Pending?
    private let readContext: () -> Action.Context
    private let readScope: () -> ReadScope?
    private let prepare: (Action.Operation) -> UInt64?
    private let cancelPreparation: (Action.Operation) -> Void
    private let finishPreparation: (Action.Operation) -> Void
    private let send: (ConfiguredCraftActionControl, ReadScope, Action.Fence?) -> Bool
    private let cancelSend: (UUID) -> Void
    private let clock: () -> Double
    private var executing = false
    private var deadlineWork: DispatchWorkItem?
    private var deadline: Double?
    private var deadlineOperation: UUID?

    init(context: @escaping () -> Action.Context, readScope: @escaping () -> ReadScope?,
         prepare: @escaping (Action.Operation) -> UInt64?,
         cancelPreparation: @escaping (Action.Operation) -> Void,
         finishPreparation: @escaping (Action.Operation) -> Void,
         send: @escaping (ConfiguredCraftActionControl, ReadScope, Action.Fence?) -> Bool,
         cancelSend: @escaping (UUID) -> Void,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        readContext = context; self.readScope = readScope; self.prepare = prepare
        self.cancelPreparation = cancelPreparation; self.finishPreparation = finishPreparation
        self.send = send; self.cancelSend = cancelSend; self.clock = clock
    }
    deinit { deadlineWork?.cancel() }

    var context: Action.Context {
        var value = readContext()
        value.capabilityPresent = capability && scope != nil && scope == readScope()
        value.routeImplemented = value.capabilityPresent
        value.binding = nil; value.routeGeneration = nil
        if value.capabilityPresent, let catalog, let scope, let profile = UUID(uuidString: catalog.expectedProfileId) {
            value.binding = .init(deviceId: scope.device.hex, profileId: profile, assignmentSha256: catalog.expectedAssignmentSha256)
            value.routeGeneration = catalogRevision
        }
        return value
    }
    var canBegin: Bool { pending == nil && model.canBegin(context) }
    var canReadCatalog: Bool {
        guard capability, readScope() != nil, pending == nil else { return false }
        switch model.phase {
        case .preparing, .ready, .awaiting: return false
        default: return true
        }
    }
    var canQuery: Bool {
        guard canReadCatalog, let scope = readScope(), let operation = model.operation,
              operation.fence.hostKey == scope.hostKey, operation.request.deviceId == scope.device else { return false }
        switch model.phase {
        case .unknown: return true
        case .completed(_, let result): return result.outcome == .unknown
        default: return false
        }
    }
    var message: String? {
        let result = problem ?? model.message
        if !context.invocationAllowed {
            return "센트리 보호가 켜져 있거나 상태가 미확인이어서 음성 명령을 실행할 수 없습니다." +
                (result.map { " " + $0 } ?? "")
        }
        return result
    }
    func observe(capability: Int?) {
        self.capability = capability == 1
        refresh()
    }
    func begin(heldFor: Double, issuedAt: Date = Date()) {
        guard !executing, canBegin else { return }
        executing = true
        execute(model.begin(heldFor: heldFor, context: context, now: clock(), issuedAt: issuedAt))
        executing = false; scheduleDeadline()
    }
    func refresh() {
        guard !executing else { return }
        executing = true
        let current = capability ? readScope() : nil
        if scope != current {
            clearPending(); scope = current; catalog = nil; catalogRevision = nil
            catalogAttempted = false; problem = nil
        }
        if let pending, clock() >= pending.until {
            clearPending(); problem = "음성 명령 응답을 확인하지 못했습니다."
        }
        execute(model.advance(context: context, now: clock()))
        if capability, scope != nil, !catalogAttempted, pending == nil {
            catalogAttempted = true
            submit(.init(requestId: UUID()), fence: nil)
        }
        executing = false; scheduleDeadline()
    }
    func cancel(operationId: UUID? = nil) {
        if let operationId, model.operation?.request.operationId != operationId { return }
        guard !executing else { return }
        executing = true
        execute(model.cancel())
        if pending?.control.operation == .invoke { clearPending() }
        executing = false; scheduleDeadline()
    }
    func readCatalog() {
        refresh()
        guard canReadCatalog else { return }
        submit(.init(requestId: UUID()), fence: nil); scheduleDeadline()
    }
    func query() {
        refresh()
        guard canQuery, let operation = model.operation else { return }
        submit(.init(requestId: UUID(), operationId: operation.request.operationId), fence: nil)
        scheduleDeadline()
    }
    @discardableResult
    func receive(_ data: Data, in incoming: ReadScope) -> Bool {
        guard let pending, scope == incoming, readScope() == incoming, pending.scope == incoming,
              clock().isFinite, clock() < pending.until,
              let state = try? ConfiguredCraftActionState.decode(data), state.deviceId == incoming.device,
              state.matches(pending.control) else { return false }
        if let result = state.result {
            let accepted = pending.control.operation == .query ?
                model.receiveReadback(result, hostKey: incoming.hostKey, device: incoming.device) :
                model.receive(result, context: context, now: clock())
            guard accepted else { return false }
        }
        submitted(state.requestId)
        clearPending()
        if let catalog = state.catalog {
            if self.catalog != catalog { catalogRevision = UUID() }
            self.catalog = catalog; problem = nil
        } else if state.result != nil {
            problem = nil
        } else if let error = state.error {
            problem = "음성 명령 결과 미확인 (" + error + ")"
            if pending.control.operation == .invoke { execute(model.cancel()) }
        }
        refresh(); return true
    }
    private func submit(_ control: ConfiguredCraftActionControl, fence: Action.Fence?) {
        guard pending == nil, capability, let scope, scope == readScope() else { return }
        problem = nil
        pending = .init(control: control, scope: scope, until: clock() + Action.responseBudget)
        if !send(control, scope, fence) {
            clearPending(); problem = "음성 명령 요청을 보내지 못했습니다."
            if control.operation == .invoke { execute(model.cancel()) }
        }
        objectWillChange.send()
    }
    private func clearPending() {
        let id = pending?.control.requestId
        pending = nil
        if let id { cancelSend(id) }
    }
    func sendCancelled(_ id: UUID) {
        guard pending?.control.requestId == id else { return }
        let invoke = pending?.control.operation == .invoke
        clearPending()
        if invoke { execute(model.cancel()) }
        problem = "음성 명령 요청의 전송을 확인하지 못했습니다."
        scheduleDeadline()
    }
    func submitted(_ id: UUID) {
        guard var pending, pending.control.requestId == id, !pending.submitted,
              pending.control.operation == .invoke, pending.scope == readScope(),
              let operation = model.operation, pending.control.targetOperationId == operation.request.operationId,
              context.fence == operation.fence else { return }
        pending.submitted = true
        self.pending = pending
        finishPreparation(operation)
    }
    private func execute(_ effect: Action.Effect?) {
        guard let effect else { return }
        switch effect {
        case .prepare(let operation):
            guard context.fence == operation.fence, let revision = prepare(operation) else {
                execute(model.cancel()); return
            }
            if context.fence != operation.fence {
                guard model.recordPreparedSelection(operationId: operation.request.operationId,
                    revision: revision, context: context) else { execute(model.cancel()); return }
            }
            execute(model.advance(context: context, now: clock()))
        case .invoke(let operation):
            guard pending == nil, let request = model.takeInvocation(operation, context: context, now: clock()) else {
                cancelPreparation(operation); execute(model.cancel()); return
            }
            submit(.init(requestId: UUID(), client: request), fence: operation.fence)
        case .cancelPreparation(let operation):
            cancelPreparation(operation)
            if pending?.control.targetOperationId == operation.request.operationId { clearPending() }
        }
    }
    private func scheduleDeadline() {
        let next: Double?
        switch model.phase {
        case .preparing(_, _, let until), .ready(_, _, let until), .awaiting(_, _, let until): next = until
        default: next = nil
        }
        let effective = [next, pending?.until].compactMap { $0 }.min()
        let id = pending?.control.requestId ?? model.operation?.request.operationId
        guard effective != deadline || id != deadlineOperation else { return }
        deadlineWork?.cancel(); deadlineWork = nil; deadline = effective; deadlineOperation = id
        guard let effective else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.deadline == effective, self.deadlineOperation == id else { return }
            self.refresh()
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, effective - clock()), execute: work)
    }
}

#if os(visionOS)
extension StreamClient {
    var visionConfiguredCraftContext: VisionConfiguredCraftAction.Context { visionConfiguredCraftAction.context }
    var visionConfiguredCraftReadScope: VisionConfiguredCraftActionExecutor.ReadScope? {
        guard visionAudioIntentContext.connected, visionStartupForeground, appInForeground, microphoneAdmission.active,
              let key = visionAudioTrustedHostKey, let lease = visionDisplaySelection.lease,
              lease == microphoneAdmission.lease,
              let fingerprint = DeviceIdentity.existing()?.fingerprint,
              let device = AudioForwardingDeviceID(fingerprint: fingerprint) else { return nil }
        return .init(hostKey: key, connection: visionAudioIntentConnection, window: lease.window,
            admission: lease.admission, foreground: visionAudioIntentForeground,
            video: visionAudioIntentContext.scope?.video, device: device)
    }
    var visionConfiguredCraftMediaContext: VisionConfiguredCraftAction.Context {
        let audioContext = visionAudioIntentContext
        var context = VisionConfiguredCraftAction.Context()
        context.hostKey = audioContext.hostKey; context.scope = audioContext.scope
        context.admitted = audioContext.admitted && visionConfiguredCraftFocused
        context.invocationAllowed = visionSentrySnapshot.permitsConfiguredCraftInvocation
        context.selection = visionStoredAudioSelection?.desire
        context.selectionRevision = visionStoredAudioSelection?.revision ?? 0
        let routes = visionMacAudioRoutes
        context.otherDeviceSelected = routes.hasExplicitSelection
        context.deviceRouteRevision = context.otherDeviceSelected ? routes.model.catalogToken?.revision : nil
        if context.otherDeviceSelected && (routes.scope == nil || routes.catalogInvalid || routes.model.pending != nil) {
            context.admitted = false
        }
        if let snapshot = visionForwarding?.providerCallSnapshot, let intent = snapshot.intent {
            let speakerReady: Bool
            switch visionAudio.presentation.phase {
            case .waiting, .rendering: speakerReady = true
            default: speakerReady = false
            }
            context.readback = .init(desire: .init(playback: intent.outputDesired, microphone: intent.inputDesired),
                microphoneReady: audioContext.eligible && microphonePhase == .live && visionForwarding?.permits(.microphone) == true,
                speakerReady: audioContext.eligible && speakerReady && visionForwarding?.permits(.playback) == true,
                microphoneOff: (microphonePhase == .off || microphonePhase == .unavailable) && microphoneCleanupProblem == nil,
                speakerOff: visionAudio.presentation.phase == .off && visionAudio.cleanupProblem == nil)
        }
        return context
    }
}
#endif
