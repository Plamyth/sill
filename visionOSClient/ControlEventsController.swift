import Foundation
import Combine

@MainActor
final class ControlEventsController: ObservableObject {
    @Published private(set) var reducer = ControlEventsReducer()
    @Published private(set) var projection: ControlEventsProjection?
    @Published var selection = ControlEventsSelection()
    @Published private(set) var message = "연결 정보 미제공 · 이 Vision 앱의 기기 등록이 필요합니다. Sill 연결 인증과는 별도입니다."
    private var gateway: ControlEventsGateway?
    private var task: Task<Void, Never>?
    private var operation: UUID?
    private var foreground = false
    private var visible = false
    private var released = false
    private let stream: (ControlEventsGateway) -> AsyncThrowingStream<ControlEventsStreamItem, Error>
    private let sleep: (UInt64) async throws -> Void

    init(stream: @escaping (ControlEventsGateway) -> AsyncThrowingStream<ControlEventsStreamItem, Error> = ControlEventsTransport.stream,
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.stream = stream
        self.sleep = sleep
    }
    var configured: Bool { gateway != nil }
    deinit { task?.cancel() }

    func configure(_ gateway: ControlEventsGateway?) {
        stop()
        self.gateway = gateway
        reducer = ControlEventsReducer()
        projection = nil
        selection.workID = nil
        reconcile()
    }
    func setForeground(_ active: Bool) { foreground = active; if !active { stop() } else { reconcile() } }
    func setVisible(_ value: Bool) { visible = value; if !value { stop() } else { reconcile() } }
    func claim() { released = false }
    func release() { released = true; foreground = false; visible = false; stop() }
    func reconnect() { stop(); reconcile() }

    private func stop() {
        operation = nil
        if let id = reducer.subscription { reducer.stop(id) }
        task?.cancel()
        task = nil
    }

    private func reconcile() {
        guard !released, foreground, visible, task == nil else { return }
        guard let gateway else {
            message = "연결 정보 미제공 · 이 Vision 앱의 기기 등록이 필요합니다. Sill 연결 인증과는 별도입니다."
            return
        }
        let operation = UUID()
        self.operation = operation
        task = Task { [weak self] in await self?.subscribe(gateway, operation: operation) }
    }

    private func subscribe(_ gateway: ControlEventsGateway, operation: UUID) async {
        var retry = ControlEventsRetryPolicy()
        var resyncAttempts = 0
        while self.operation == operation, !Task.isCancelled {
            let id = UUID()
            reducer.begin(id)
            message = "이벤트 연결을 준비하고 있습니다. 최초 상태를 확인하기 전입니다."
            var resync = false
            do {
                for try await item in stream(gateway) {
                    guard self.operation == operation, reducer.subscription == id, !Task.isCancelled else { return }
                    switch item {
                    case .opened(let date):
                        reducer.opened(id, at: date)
                        message = "이벤트 통로에 연결되었습니다. 최초 상태를 기다립니다."
                    case .envelope(let envelope):
                        var candidate = reducer
                        switch candidate.consume(envelope, subscription: id) {
                        case .applied:
                            guard let document = candidate.document else { throw ControlEventsTransportFailure.payload }
                            let contract = gateway.contract
                            let projected = try await Task.detached { try contract.project(document) }.value
                            guard self.operation == operation, reducer.subscription == id, !Task.isCancelled else { return }
                            guard Self.valid(projected) else { throw ControlEventsTransportFailure.payload }
                            if reducer.version?.generation != candidate.version?.generation { selection.workID = nil }
                            reducer = candidate
                            projection = projected
                            selection.reconcile(projected)
                            if case .patch = envelope { retry.progressed(); resyncAttempts = 0 }
                            message = "연결 서버 상태를 동기화했습니다. 원본 이벤트 지원과 각 관측은 별도로 확인하세요."
                        case .heartbeat, .ignored: break
                        case .invalid: throw ControlEventsTransportFailure.payload
                        case .resyncRequired: reducer = candidate; resync = true
                        }
                    }
                    if resync { break }
                }
                if !resync { throw ControlEventsTransportFailure.streamEnded }
                reducer.stop(id)
                resyncAttempts += 1
                guard resyncAttempts <= 1 else { throw ControlEventsTransportFailure.payload }
                message = "이벤트 세대 또는 순서가 달라 최초 상태를 다시 요청합니다."
            } catch {
                guard self.operation == operation, !Task.isCancelled else { return }
                reducer.stop(id, failed: true)
                guard let delay = retry.delay(for: error) else {
                    message = (error as? ControlEventsTransportFailure)?.message ?? "이벤트 연결 또는 보안 검증에 실패했습니다. 마지막 관측만 표시합니다."
                    self.operation = nil
                    task = nil
                    return
                }
                message = "이벤트 연결이 끊겨 잠시 후 다시 연결합니다. 기존 정보는 마지막 관측입니다."
                do { try await sleep(delay) } catch { return }
                guard self.operation == operation, foreground, visible, !released, !Task.isCancelled else { return }
            }
        }
    }

    private static func valid(_ projection: ControlEventsProjection) -> Bool {
        guard projection.work.count <= ControlEventsReducer.maximumRecords,
              Set(projection.sources.map(\.provider)).count == projection.sources.count,
              Set(projection.work.map(\.id)).count == projection.work.count else { return false }
        return projection.work.allSatisfy { work in
            let ids = [work.id.originalID, work.id.sessionID, work.id.runID, work.ownerID,
                       work.id.instanceID, work.id.workspaceIdentity, work.id.hostID, work.id.rowKey].compactMap { $0 }
            return ids.allSatisfy(ControlEventsReducer.validID) && work.title.utf8.count <= 8192
        }
    }
}
