import Foundation
import Combine

@MainActor
final class IPadAppUpdateController: ObservableObject {
    enum State: Equatable {
        case unconfigured
        case checking
        case upToDate(IPadAppUpdateRelease?)
        case available(IPadAppUpdateRelease)
        case handoffPending(IPadAppUpdateRelease)
        case verifiedInstalled(IPadAppUpdateRelease)
        case failed(IPadAppUpdateError)
    }

    private struct Pending: Codable {
        enum Phase: String, Codable { case observed, opening, opened, openFailed, interrupted }
        let envelope: Data
        let handoffProcessID: UUID?
        let requestID: UUID?
        let phase: Phase
    }

    nonisolated static let pendingKey = "CCR.IPadAppUpdate.pending.v1"
    nonisolated private static let processID = UUID()
    @Published private(set) var state: State
    private(set) var installed: IPadAppUpdateInstalled
    private let configuration: IPadAppUpdateConfiguration?
    private let readInstalled: () -> IPadAppUpdateInstalled
    private let loadPending: () -> Data?
    private let savePending: (Data) -> Void
    private let fetch: (IPadAppUpdateConfiguration) async throws -> Data
    private let now: () -> Date
    private let processID: UUID
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(configuration: IPadAppUpdateConfiguration? = .bundled(),
         readInstalled: @escaping () -> IPadAppUpdateInstalled = { .read() },
         loadPending: @escaping () -> Data? = { UserDefaults.standard.data(forKey: pendingKey) },
         savePending: @escaping (Data) -> Void = { UserDefaults.standard.set($0, forKey: pendingKey) },
         fetch: @escaping (IPadAppUpdateConfiguration) async throws -> Data = {
             try await IPadAppUpdateFeed.fetch($0, authenticatedRequest: nil)
         },
         now: @escaping () -> Date = Date.init,
         processID: UUID = IPadAppUpdateController.processID) {
        self.configuration = configuration
        self.readInstalled = readInstalled
        self.loadPending = loadPending
        self.savePending = savePending
        self.fetch = fetch
        self.now = now
        self.processID = processID
        installed = readInstalled()
        state = configuration == nil ? .unconfigured : .upToDate(nil)
        readback()
    }

    func readback() {
        installed = readInstalled()
        guard let configuration else { state = .unconfigured; return }
        guard task == nil, let data = loadPending() else { return }
        do {
            let pending = try JSONDecoder().decode(Pending.self, from: data)
            let release = try IPadAppUpdatePolicy.authenticate(pending.envelope, configuration: configuration,
                                                               now: now(), requireFresh: false)
            guard pending.phase != .observed else { return }
            if pending.phase == .openFailed { state = .failed(.openFailed); return }
            if pending.phase == .interrupted { state = .failed(.cancelled); return }
            guard pending.phase == .opened, let handoffProcessID = pending.handoffProcessID else {
                state = .failed(.handoffUnknown)
                return
            }
            if handoffProcessID != processID, installed.matches(release) {
                state = .verifiedInstalled(release)
            } else {
                _ = try IPadAppUpdatePolicy.authenticate(pending.envelope, configuration: configuration, now: now())
                _ = try IPadAppUpdatePolicy.validateProgress(release, installed: installed, previous: nil)
                state = .handoffPending(release)
            }
        } catch {
            state = .failed(Self.problem(error))
        }
    }

    func checkAndInstall(open: @escaping (URL) async -> Bool) {
        guard task == nil else { return }
        guard let configuration else { state = .unconfigured; return }
        let request = UUID()
        requestID = request
        state = .checking
        task = Task {
            defer {
                if requestID == request {
                    task = nil
                    objectWillChange.send()
                }
            }
            do {
                let envelope = try await fetch(configuration)
                try Task.checkCancellation()
                guard requestID == request else { return }
                let release = try IPadAppUpdatePolicy.authenticate(envelope, configuration: configuration, now: now())
                var previous: IPadAppUpdateRelease?
                if let data = loadPending() {
                    let pending = try JSONDecoder().decode(Pending.self, from: data)
                    previous = try IPadAppUpdatePolicy.authenticate(pending.envelope, configuration: configuration,
                                                                   now: now(), requireFresh: false)
                }
                installed = readInstalled()
                let newer = try IPadAppUpdatePolicy.validateProgress(release, installed: installed, previous: previous)
                if !newer {
                    try persist(Pending(envelope: envelope, handoffProcessID: nil, requestID: nil, phase: .observed))
                    state = .upToDate(release)
                    return
                }
                state = .available(release)
                let url = try IPadAppUpdatePolicy.installURL(release)
                try Task.checkCancellation()
                try persist(Pending(envelope: envelope, handoffProcessID: processID, requestID: request, phase: .opening))
                _ = try IPadAppUpdatePolicy.authenticate(envelope, configuration: configuration, now: now())
                let opened = await open(url)
                guard !Task.isCancelled, requestID == request else { return }
                guard let data = loadPending(),
                      let pending = try? JSONDecoder().decode(Pending.self, from: data),
                      pending.requestID == request, pending.handoffProcessID == processID,
                      pending.phase == .opening, pending.envelope == envelope else { throw IPadAppUpdateError.storage }
                try persist(Pending(envelope: envelope, handoffProcessID: processID, requestID: request,
                                    phase: opened ? .opened : .openFailed))
                state = opened ? .handoffPending(release) : .failed(.openFailed)
            } catch {
                guard requestID == request else { return }
                let problem = Self.problem(error)
                state = problem == .unconfigured ? .unconfigured : .failed(problem)
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        switch state {
        case .checking, .available: break
        default: return
        }
        task?.cancel()
        task = nil
        if let data = loadPending(), let pending = try? JSONDecoder().decode(Pending.self, from: data),
           pending.requestID == requestID, pending.handoffProcessID == processID, pending.phase == .opening {
            do {
                try persist(Pending(envelope: pending.envelope, handoffProcessID: processID, requestID: requestID, phase: .interrupted))
            } catch {
                requestID = UUID()
                state = .failed(.storage)
                return
            }
        }
        requestID = UUID()
        state = .failed(.cancelled)
    }

    private func persist(_ pending: Pending) throws {
        let data = try JSONEncoder().encode(pending)
        savePending(data)
        guard loadPending() == data else { throw IPadAppUpdateError.storage }
    }

    private static func problem(_ error: Error) -> IPadAppUpdateError {
        if let error = error as? IPadAppUpdateError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if error is DecodingError { return .malformed }
        return .network
    }

    var isChecking: Bool { if case .checking = state { return true }; return false }
    var canCancel: Bool {
        switch state {
        case .checking, .available: return task != nil
        default: return false
        }
    }
    var canCheck: Bool { configuration != nil && task == nil }

    var message: String {
        switch state {
        case .unconfigured:
            return configuration == nil
                ? "배포채널 준비중. 승인된 업데이트 주소와 검증 키가 앱에 아직 등록되지 않았습니다."
                : "배포채널 준비중. 서버에 승인된 업데이트가 아직 준비되지 않았습니다. 다시 시도하세요."
        case .checking: return "승인된 최신 업데이트를 조회하고 서명을 확인하는 중입니다."
        case .upToDate(nil): return "아직 최신 업데이트를 조회하지 않았습니다."
        case .upToDate(.some): return "승인된 최신 버전과 현재 실행 중인 앱의 버전·빌드·소스가 일치합니다."
        case .available(let release): return "승인된 \(release.version) (빌드 \(release.build))의 Apple 설치 화면을 여는 중입니다."
        case .handoffPending: return "Apple 설치 화면에 전달했습니다. OS의 설치 확인이 남아 있습니다. 설치 후 앱을 다시 실행하면 버전·빌드·소스를 확인합니다."
        case .verifiedInstalled: return "새 앱 프로세스의 버전·빌드·소스가 승인된 업데이트와 정확히 일치합니다."
        case .failed(let error): return error.localizedDescription
        }
    }
}
