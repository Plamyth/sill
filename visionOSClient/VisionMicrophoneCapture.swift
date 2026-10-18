import AVFoundation
import Foundation
import os

final class VisionMicrophoneCapture {
    private struct Input { var conversionID: UUID? }
    private struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let hardware: VisionAudioHardware
    private let owner: UUID
    private let requestPermission: () async -> Bool
    private let permitted: () -> Bool
    private let closeFrames: @Sendable () -> Void
    private let failed: (String) -> Void
    private let worker = IPadMicrophoneConversionWorker()
    private let input = OSAllocatedUnfairLock(initialState: Input())
    private var attempt: UUID?
    private var claim: VisionAudioClaim?
    private var completion: CheckedContinuation<Void, Error>?
    private var formatProblem: String?

    init(hardware: VisionAudioHardware, owner: UUID, permitted: @escaping () -> Bool,
         requestPermission: @escaping () async -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         closeFrames: @escaping @Sendable () -> Void, failed: @escaping (String) -> Void) {
        self.hardware = hardware
        self.owner = owner
        self.permitted = permitted
        self.requestPermission = requestPermission
        self.closeFrames = closeFrames
        self.failed = failed
    }

    @MainActor
    func start(emit: @escaping @Sendable ([IPadMicrophonePCMFrame]) -> Void) async throws {
        guard attempt == nil, claim == nil, hardware.cleanupProblem == nil, permitted() else { throw CancellationError() }
        let token = UUID()
        attempt = token
        guard await requestPermission() else {
            if attempt == token { attempt = nil }
            throw Problem(message: "Vision 마이크 권한이 필요합니다.")
        }
        guard attempt == token, permitted() else {
            if attempt == token { attempt = nil }
            throw CancellationError()
        }
        let worker = worker, input = input
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion = continuation
                do {
                    claim = try hardware.beginCapture(owner: owner, epoch: token, permitted: { [weak self] in
                        guard let self else { return false }
                        return self.attempt == token && self.permitted()
                    }, formatChanged: { [weak self] format in
                        guard let self, self.attempt == token else { return }
                        let continuing = input.withLock { value -> Bool in
                            let previous = value.conversionID
                            value.conversionID = nil
                            return previous != nil
                        }
                        guard let id = worker.beginBatch(inputFormat: format, continuingStream: continuing, emit: emit) else {
                            self.formatProblem = "Vision 마이크 소리를 전송 형식으로 바꿀 수 없습니다."
                            return
                        }
                        self.formatProblem = nil
                        input.withLock { $0.conversionID = id }
                    }, copyInput: { buffer, _ in
                        guard let id = input.withLockIfAvailable({ $0.conversionID }) ?? nil else { return }
                        worker.enqueue(buffer, captureID: id)
                    }, stopped: { [weak self] reason in
                        self?.nativeStopped(reason)
                    }, ready: { [weak self] in
                        guard let self, self.attempt == token else { return }
                        if let problem = self.formatProblem { self.nativeStopped(problem); return }
                        guard self.permitted() else { self.finish(.failure(CancellationError())); return }
                        self.finish(.success(()))
                    })
                } catch { finish(.failure(error)) }
            }
            guard attempt == token, permitted() else { throw CancellationError() }
        } catch {
            let startError = error
            do { try stop() } catch { throw error }
            throw startError
        }
    }

    func stop() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        closeFrames()
        attempt = nil
        input.withLock { $0.conversionID = nil }
        if let claim { hardware.revoke(claim) }
        finish(.failure(CancellationError()))
        worker.end()
        if let claim, let problem = hardware.close(claim) { throw Problem(message: problem) }
        if let problem = hardware.cleanupProblem(owner: owner) { throw Problem(message: problem) }
        claim = nil
    }

    func retryCleanup() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        do { try stop(); return } catch {
            if let problem = hardware.retryCleanup(owner: owner) { throw Problem(message: problem) }
            claim = nil
        }
    }

    private func nativeStopped(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        closeFrames()
        input.withLock { $0.conversionID = nil }
        failed(reason)
        worker.end()
        finish(.failure(Problem(message: reason)))
    }

    private func finish(_ result: Result<Void, Error>) {
        let previous = completion
        completion = nil
        previous?.resume(with: result)
    }

    deinit {
        closeFrames()
        input.withLock { $0.conversionID = nil }
        let worker = worker, hardware = hardware, claim = claim
        if let claim { hardware.revoke(claim) }
        DispatchQueue.main.async {
            worker.end()
            if let claim { _ = hardware.close(claim) }
        }
    }
}
