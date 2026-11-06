import Foundation

struct VisionConfiguredCraftAction {
    static let holdDuration = 0.5
    static let preparationBudget = 8.0
    static let responseBudget = 10.0

    struct Binding: Equatable {
        let deviceId: String
        let profileId: UUID
        let assignmentSha256: String
    }

    struct CatalogRequest: Encodable {
        let schemaVersion = 1
        let operation = "get-configured-craft-action"
    }
    struct Catalog: Decodable {
        let schemaVersion: Int
        let supported: Bool
        let expectedProfileId: UUID
        let inputID: String
        let trigger: String
        let expectedAssignmentSha256: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, supported, expectedProfileId, inputID, trigger, expectedAssignmentSha256
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            supported = try values.decode(Bool.self, forKey: .supported)
            expectedProfileId = try values.decode(UUID.self, forKey: .expectedProfileId)
            inputID = try values.decode(String.self, forKey: .inputID)
            trigger = try values.decode(String.self, forKey: .trigger)
            expectedAssignmentSha256 = try values.decode(String.self, forKey: .expectedAssignmentSha256)
            guard schemaVersion == 1, supported, inputID == "speed.button.stop-play", trigger == "longPress",
                  expectedAssignmentSha256.utf8.count == 64,
                  expectedAssignmentSha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "공통 Craft catalog를 확인하지 못했습니다."))
            }
        }
    }
    struct Request: Encodable, Equatable {
        let schemaVersion = 1
        let operation = "invoke-configured-craft-action"
        let operationId: UUID
        let deviceId: String
        let inputID = "speed.button.stop-play"
        let trigger = "longPress"
        let expectedProfileId: UUID
        let expectedAssignmentSha256: String
        let issuedAt: Int64
    }

    struct Result: Decodable, Equatable {
        enum Outcome: String, Decodable { case invoked, rejected, unknown }
        let outcome: Outcome
        let operationId: UUID
        let deviceId: String
        let bindingSha256: String?
        let invoked: Bool
        let effectConfirmed: Bool
        let reason: String?
        private enum CodingKeys: String, CodingKey {
            case outcome, operationId, deviceId, bindingSha256, invoked, effectConfirmed, reason
        }
    }

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
    }
    struct MediaReadback {
        let desire: VisionRemoteAudioIntent.Desire
        let microphoneReady: Bool
        let speakerReady: Bool
        let microphoneOff: Bool
        let speakerOff: Bool
    }

    struct Context {
        var hostKey: String?
        var scope: VisionRemoteAudioIntent.Scope?
        var binding: Binding?
        var routeGeneration: UUID?
        var capabilityPresent = false
        var routeImplemented = false
        var admitted = false
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
            guard capabilityPresent, routeImplemented, admitted,
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
              epochMilliseconds.isFinite, epochMilliseconds >= 0, epochMilliseconds < Double(Int64.max),
              canBegin(context), let fence = context.fence else { return nil }
        let request = Request(operationId: operationId(), deviceId: fence.binding.deviceId,
            expectedProfileId: fence.binding.profileId,
            expectedAssignmentSha256: fence.binding.assignmentSha256, issuedAt: Int64(epochMilliseconds))
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
            guard context.fence == operation.fence, now.isFinite, now >= since, now < until else {
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
}

extension VisionConfiguredCraftAction.Result {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.bindingSha256) else {
            throw DecodingError.keyNotFound(CodingKeys.bindingSha256,
                .init(codingPath: decoder.codingPath, debugDescription: "bindingSha256 필드는 null이어도 필요합니다."))
        }
        outcome = try values.decode(Outcome.self, forKey: .outcome)
        operationId = try values.decode(UUID.self, forKey: .operationId)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        bindingSha256 = try values.decodeIfPresent(String.self, forKey: .bindingSha256)
        invoked = try values.decode(Bool.self, forKey: .invoked)
        effectConfirmed = try values.decode(Bool.self, forKey: .effectConfirmed)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
    }
}
