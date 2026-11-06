import Foundation
import StreamProtocol

/// Only public identities and the unresolved request are persisted, never TLS/session credentials.
struct IPadCraftActionJournal {
    struct Owner: Codable, Equatable {
        let macID: String
        let hostPin: String
        let deviceID: String
    }
    struct Record: Codable {
        let owner: Owner
        let request: ConfiguredCraftActionRequest
    }
    private struct Archive: Codable {
        let version: Int
        let unresolved: Record?
    }
    let read: () throws -> Record?
    let write: (Record?) throws -> Void

    static func file(_ url: URL) -> Self {
        Self(read: {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= 8192 else { throw IPadConfiguredCraftAction.Failure.invalidWire }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw IPadConfiguredCraftAction.Failure.invalidWire }
            if let record = archive.unresolved {
                guard AudioForwardingDeviceID(hex: record.owner.hostPin) != nil,
                      !record.owner.macID.isEmpty, record.owner.macID.utf8.count <= 256,
                      record.owner.deviceID == record.request.deviceId.hex else {
                    throw IPadConfiguredCraftAction.Failure.invalidWire
                }
                _ = try ConfiguredCraftActionControl.decode(JSONEncoder().encode(
                    ConfiguredCraftActionControl(requestId: UUID(), client: record.request)))
            }
            return archive.unresolved
        }, write: { record in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(version: 1, unresolved: record))
            try data.write(to: url, options: .atomic)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            // Readback is part of admission; a failed write/read leaves the caller blocked.
            guard try Data(contentsOf: url) == data else {
                throw IPadConfiguredCraftAction.Failure.invalidWire
            }
        })
    }

    static func application() -> Self {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return Self(read: { throw IPadConfiguredCraftAction.Failure.invalidContext },
                        write: { _ in throw IPadConfiguredCraftAction.Failure.invalidContext })
        }
        return file(directory.appendingPathComponent("ConfiguredCraftAction/unresolved-v1.json"))
    }
}

/// Production state machine shared by the app adapter and the finite, network-free checks.
struct IPadCraftConnectedControl {
    typealias Context = IPadConfiguredCraftAction.Context
    typealias Owner = IPadCraftActionJournal.Owner
    struct Exchange {
        let context: Context
        let control: ConfiguredCraftActionControl
        let deadline: TimeInterval
    }
    private(set) var model: IPadConfiguredCraftAction
    private(set) var context: Context?
    private(set) var owner: Owner?
    private(set) var advertised = false
    private(set) var catalog: IPadConfiguredCraftAction.Catalog?
    private(set) var exchange: Exchange?
    private(set) var unresolved: IPadCraftActionJournal.Record?
    private(set) var storageFailed = false
    private(set) var message = "음성 대화 동작을 확인하는 중입니다."
    private var catalogAttempted = false
    private let journal: IPadCraftActionJournal
    private let clock: () -> TimeInterval

    init(journal: IPadCraftActionJournal = .application(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.journal = journal; self.clock = clock
        model = IPadConfiguredCraftAction(clock: clock)
        do { unresolved = try journal.read() }
        catch { storageFailed = true; message = "이전 요청 기록을 읽을 수 없어 실행하지 않습니다." }
        if unresolved != nil { message = "이전 음성 대화 요청의 결과를 확인해야 합니다." }
    }

    var canPrepare: Bool { advertised && context != nil && catalog != nil && exchange == nil && unresolved == nil && !storageFailed }
    var canQuery: Bool { advertised && context != nil && unresolved?.owner == owner && unresolved != nil && exchange == nil && !storageFailed }

    static func legacyAllowsNewAction(_ legacy: IPadProviderCall) -> Bool {
        guard legacy.pending == nil, legacy.activeCall == nil else { return false }
        if legacy.request == nil { return true }
        return [legacy.result, legacy.historicalResult].contains { result in
            result.map { [.stopped, .failed, .unsupported].contains($0.status) } == true
        }
    }

    static func audioReady(_ forwarding: IPadAudioForwarding, context: IPadAudioForwarding.Context?,
                           selection: IPadDesiredAudio.Selection, faulted: Bool,
                           inputReady: Bool, outputReady: Bool, now: TimeInterval) -> Bool {
        guard !faulted, let context, context == forwarding.context,
              let snapshot = forwarding.snapshot, let binding = forwarding.binding, binding == snapshot.binding,
              binding.pairedDeviceId == context.device, binding.transportKind == .native,
              let durable = forwarding.durable, durable.device == context.device,
              durable.selection == selection, binding.intentGeneration == durable.generation,
              snapshot.intent?.pairedDeviceId == context.device,
              snapshot.intent?.intentId == durable.intentID,
              snapshot.intent?.intentGeneration == durable.generation else { return false }
        if !selection.microphone && !selection.playback {
            guard let observed = forwarding.receivedSummary(in: context)?["observedUptimeSeconds"],
                  let time = TimeInterval(observed), time.isFinite, now >= time, now < time + 3 else { return false }
            return binding.phase == .off && forwarding.phase == .ready
        }
        guard binding.phase == .active, forwarding.phase == .active,
              let deadline = forwarding.mediaDeadline, now < deadline else { return false }
        return (!selection.microphone || inputReady) && (!selection.playback || outputReady)
    }

    mutating func observe(context next: Context?, owner nextOwner: Owner?, capability: Int?) {
        let supported = capability == 1 && next != nil && nextOwner != nil &&
            next?.hostID == nextOwner?.hostPin && next?.deviceID == nextOwner?.deviceID
        if context != next || owner != nextOwner || advertised != supported {
            context = next; owner = nextOwner; advertised = supported
            exchange = nil; catalog = nil; catalogAttempted = false
            if let next { model.bind(next) } else { model.disconnected() }
            if let record = unresolved, let next, record.owner == nextOwner,
               let request = try? JSONDecoder().decode(IPadConfiguredCraftAction.Request.self, from: JSONEncoder().encode(record.request)) {
                try? model.restoreUnresolved(request, in: next)
            }
        }
        if !supported { message = "현재 Mac은 음성 대화 공통 동작을 지원하지 않습니다." }
    }

    mutating func catalogRequest(explicit: Bool = false) -> ConfiguredCraftActionControl? {
        guard advertised, let context, exchange == nil, explicit || !catalogAttempted else { return nil }
        catalogAttempted = true
        catalog = nil
        let control = ConfiguredCraftActionControl(requestId: UUID())
        exchange = Exchange(context: context, control: control, deadline: clock() + 10)
        return control
    }

    mutating func invoke(userAction: UUID, heldMilliseconds: Int, issuedAt: Int64,
                         inputReady: Bool, outputReady: Bool, sentryInactive: Bool) -> ConfiguredCraftActionControl? {
        guard canPrepare, sentryInactive, issuedAt > 0, issuedAt <= 9_007_199_254_740_991,
              let context, let owner, let catalog else { return nil }
        _ = model.observe(from: context, authenticated: true, endpointSupported: advertised,
                          catalog: catalog, inputReady: inputReady, outputReady: outputReady)
        guard let request = model.begin(from: context, catalog: catalog, userActionID: userAction,
                                        heldMilliseconds: heldMilliseconds, issuedAt: issuedAt) else { return nil }
        do {
            guard let device = AudioForwardingDeviceID(hex: request.deviceId) else { throw IPadConfiguredCraftAction.Failure.invalidContext }
            let descriptor = try ConfiguredCraftActionCatalog(expectedProfileId: request.expectedProfileId,
                                                               expectedAssignmentSha256: request.expectedAssignmentSha256)
            let wire = try ConfiguredCraftActionRequest(operationId: request.operationId, deviceId: device,
                                                        catalog: descriptor, issuedAt: request.issuedAt)
            let control = ConfiguredCraftActionControl(requestId: UUID(), client: wire)
            _ = try ConfiguredCraftActionControl.decode(JSONEncoder().encode(control))
            let record = IPadCraftActionJournal.Record(owner: owner, request: wire)
            // A write may have reached disk even if its readback fails. Retain the same ID in memory.
            unresolved = record
            try journal.write(record)
            exchange = Exchange(context: context, control: control, deadline: clock() + 10)
            message = "음성 대화 동작의 실행 접수를 확인하는 중입니다."
            return control
        } catch {
            storageFailed = true
            message = "요청 기록을 저장하지 못해 실행하지 않았습니다."
            return nil
        }
    }

    mutating func query() -> ConfiguredCraftActionControl? {
        guard canQuery, let context, let record = unresolved else { return nil }
        let control = ConfiguredCraftActionControl(requestId: UUID(), operationId: record.request.operationId)
        exchange = Exchange(context: context, control: control, deadline: clock() + 10)
        return control
    }

    @discardableResult
    mutating func receive(_ bytes: Data, from incoming: Context) -> Bool {
        guard let pending = exchange, incoming == context, pending.context == incoming,
              clock() < pending.deadline,
              let state = try? ConfiguredCraftActionState.decode(bytes), state.matches(pending.control),
              state.deviceId.hex == incoming.deviceID else { return false }
        if let descriptor = state.catalog {
            guard let profile = UUID(uuidString: descriptor.expectedProfileId),
                  let catalog = try? IPadConfiguredCraftAction.Catalog(context: incoming, profileID: profile,
                        assignmentSha256: descriptor.expectedAssignmentSha256) else { return false }
            self.catalog = catalog; exchange = nil
            message = unresolved == nil ? "" : "이전 음성 대화 요청의 결과를 확인해야 합니다."
            return true
        }
        if let error = state.error {
            exchange = nil
            if pending.control.operation == .catalog { catalog = nil }
            message = pending.control.operation == .catalog ? "음성 대화 동작을 확인할 수 없습니다. (\(error))"
                : "요청 결과가 확인되지 않았습니다. (\(error))"
            return true
        }
        guard let result = state.result, let record = unresolved, record.owner == owner,
              result.operationId == record.request.operationId,
              let data = try? JSONEncoder().encode(result) else { return false }
        var resolved = model
        guard (try? resolved.resolveOriginal(data)) == true else { return false }
        if result.outcome != .unknown {
            do { try journal.write(nil) }
            catch { storageFailed = true; exchange = nil; message = "결과 기록을 저장할 수 없어 재실행하지 않습니다."; return false }
            unresolved = nil
        }
        model = resolved; exchange = nil
        switch result.outcome {
        case .invoked: message = "음성 대화 동작이 실행기에 접수되었습니다."
        case .rejected: message = "음성 대화 동작이 거절되었습니다."
        case .unknown: message = "요청 결과가 미확인입니다. 이전 요청을 확인하세요."
        }
        return true
    }

    mutating func timeout(requestID: UUID) {
        guard let pending = exchange, pending.control.requestId == requestID, clock() >= pending.deadline else { return }
        exchange = nil
        if pending.control.operation == .catalog { catalog = nil }
        if let id = pending.control.targetOperationId { _ = model.timeout(operationId: id) }
        message = pending.control.operation == .catalog ? "음성 대화 동작 확인 시간이 지났습니다."
            : "요청 결과가 미확인입니다. 이전 요청을 확인하세요."
    }
}

/// A preparation never owns the user's selection and never rolls it back on cancellation.
struct IPadCraftPreparation {
    let context: IPadConfiguredCraftAction.Context
    let selectionGeneration: UUID
    private(set) var deadline: TimeInterval?
    private(set) var cancelled = false

    init(context: IPadConfiguredCraftAction.Context, selectionGeneration: UUID) {
        self.context = context; self.selectionGeneration = selectionGeneration
    }
    mutating func cancel() { cancelled = true }
    mutating func permits(context: IPadConfiguredCraftAction.Context?, selectionGeneration: UUID,
                          foreground: Bool, permissionWaiting: Bool, backgrounded: Bool = false,
                          sentryInactive: Bool, now: TimeInterval) -> Bool {
        guard !cancelled, context == self.context, selectionGeneration == self.selectionGeneration,
              !backgrounded, sentryInactive, foreground || permissionWaiting, now.isFinite else { return false }
        if permissionWaiting { deadline = nil; return true }
        if deadline == nil { deadline = now + 8 }
        return now < deadline!
    }
}
