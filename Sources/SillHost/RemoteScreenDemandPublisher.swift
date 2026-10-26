import Foundation

@MainActor
final class RemoteScreenDemandPublisher {
    private let open: @MainActor (String, TimeInterval) async throws -> any ProviderCallTransport
    private let clock: @MainActor () -> TimeInterval
    private let commandPath: String
    private var transport: (any ProviderCallTransport)?
    private var coreGeneration: UUID?
    private var hostGeneration: UUID?
    private var revision: UInt64 = 0
    private var pending: RemoteScreenDemandObservation?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var stopped = false

    init(clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         open: @escaping @MainActor (String, TimeInterval) async throws -> any ProviderCallTransport = {
             try await ProviderCallSocket.open(path: $0, until: $1, frameLimit: 16_384)
         }) {
        self.clock = clock
        self.open = open
        commandPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexControlRoom/command.sock").path
    }

    deinit {
        worker?.cancel()
        transport?.invalidate()
    }

    func submit(_ observation: RemoteScreenDemandObservation) {
        guard !stopped, observation.revision > revision,
              hostGeneration == nil || hostGeneration == observation.hostGeneration else { return }
        hostGeneration = observation.hostGeneration
        revision = observation.revision
        pending = observation
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            while let observation = self?.takePending(id) {
                await self?.publish(observation, workerID: id)
            }
            self?.finished(id)
        }
    }

    func stop() {
        stopped = true
        workerID = nil
        pending = nil
        worker?.cancel()
        worker = nil
        transport?.invalidate()
        transport = nil
        coreGeneration = nil
    }

    private func takePending(_ id: UUID) -> RemoteScreenDemandObservation? {
        guard !stopped, workerID == id, !Task.isCancelled else { return nil }
        let next = pending
        pending = nil
        return next
    }

    private func finished(_ id: UUID) {
        guard workerID == id else { return }
        worker = nil
        workerID = nil
    }

    private func publish(_ observation: RemoteScreenDemandObservation, workerID id: UUID) async {
        var socket = transport
        do {
            if socket == nil {
                let opened = try await open(commandPath, clock() + 1)
                guard workerID == id, !stopped, !Task.isCancelled else { opened.invalidate(); return }
                transport = opened
                socket = opened
            }
            guard let socket, workerID == id, !stopped, !Task.isCancelled else { return }
            let now = clock()
            let request = try observation.request(now: now)
            let ack = try await socket.exchange(request, as: RemoteScreenDemandAcknowledgement.self, until: now + 1.5)
            guard workerID == id, !stopped, !Task.isCancelled else { return }
            try ack.validate(request, coreGeneration: coreGeneration)
            coreGeneration = ack.coreGeneration
        } catch {
            socket?.invalidate()
            guard workerID == id else { return }
            transport = nil
            coreGeneration = nil
        }
    }
}
