import AVFoundation
import Foundation
import os

private final class FakeAudioOutput {
    var duringStart: (() -> Void)?
    var startedVersions: [UInt64] = []
    var closed = 0
    func matches(_ ticket: VisionAudioTicket, version: UInt64) -> Bool { startedVersions.last == version }
    func start(_ ticket: VisionAudioTicket, format: VisionAudioFormat, version: UInt64,
               authorization: () -> VisionAudioPlaybackAuthorization, render: @escaping AVAudioSourceNodeRenderBlock) throws {
        let pending = duringStart
        duringStart = nil
        pending?()
        guard authorization() == .current else { throw CancellationError() }
        startedVersions.append(version)
    }
    func close(_ ticket: VisionAudioTicket) -> String? { closed += 1; return nil }
}

private final class ActivationHarness {
    private struct State {
        var playback = VisionAudioPlaybackState()
        var controlScheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let output = FakeAudioOutput()
    private static var now: Double { 100 }
    private func finishFailure(_ ticket: VisionAudioTicket, message: String) { _ = output.close(ticket) }

    __PRODUCTION_RECONCILE__

    func exercise() {
        let ticket = VisionAudioTicket(grant: UUID(), epoch: UUID())
        let work = VisionAudioMailbox.Work(data: Data([1]), ticket: ticket, arrived: 100, gap: 1)
        let first = VisionAudioFormat(rate: 48_000, channels: 2)!
        let second = VisionAudioFormat(rate: 44_100, channels: 1)!
        state.withLock { value in
            value.playback.begin(ticket)
            _ = value.playback.append([Float](repeating: 0.2, count: 4_000), format: first, work: work, now: 100)
        }
        output.duringStart = { [self] in
            state.withLock { value in
                _ = value.playback.append([Float](repeating: 0.3, count: 2_000), format: second, work: work, now: 100)
            }
        }
        reconcile(ticket)
        check(state.withLock { $0.playback.failure == nil && $0.playback.admits(ticket) },
              "supported activation format replacement preserves current grant")
        check(output.closed == 0, "format replacement preserves output lease for pending reconcile")
        reconcile(ticket)
        check(!output.startedVersions.isEmpty, "pending latest format can start after activation cancellation")
    }
}

func runActivationRegression() { ActivationHarness().exercise() }
