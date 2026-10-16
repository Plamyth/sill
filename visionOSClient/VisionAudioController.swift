import AVFoundation
import Combine
import Foundation
import os

struct VisionAudioControl {
    let grant: VisionAudioGrant
    let enabled: Bool
}

protocol VisionAudioPlaying: AnyObject {
    func begin(grant: UUID, onEvent: @escaping (UUID, VisionAudioPlaybackEvent) -> Void)
    func receive(_ packet: Data, grant: UUID)
    func stop()
}

extension VisionAudioPlayer: VisionAudioPlaying {}

final class VisionAudioController: ObservableObject {
    private struct Storage {
        var model = VisionAudioState()
        var revision: UInt64 = 0
    }

    @Published private(set) var presentation = VisionAudioState()
    private let storage = OSAllocatedUnfairLock(initialState: Storage())
    private let player: VisionAudioPlaying
    private let send: (VisionAudioControl) -> Void
    private let clock: () -> Double
    private var displayedRevision: UInt64 = 0
    private var deadline: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(send: @escaping (VisionAudioControl) -> Void, player: VisionAudioPlaying = VisionAudioPlayer(),
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.send = send
        self.player = player
        self.clock = clock
        #if os(visionOS)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.routeChangeNotification,
                   let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
                self?.stop(problem: "오디오 상태가 바뀌어 중지했습니다. 다시 켜려면 직접 선택하세요.")
            })
        }
        #endif
    }

    deinit {
        deadline?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        player.stop()
    }

    func update(_ availability: VisionAudioState.Availability) {
        change { model in _ = model.update(availability, foreground: model.foreground) }
    }

    func setForeground(_ foreground: Bool) {
        change { model in _ = model.update(model.availability, foreground: foreground) }
    }

    func enable() {
        change { model in
            guard model.canEnable, let grant = model.request(id: UUID(), now: clock()) else { return }
            send(VisionAudioControl(grant: grant, enabled: true))
        }
    }

    func stop(problem: String? = nil) {
        change { model in model.stop(problem: problem) }
    }

    func acknowledge(id: UUID, enabled: Bool, scope: VisionAudioScope, reason: String?) {
        change { model in
            guard let grant = model.acknowledge(id: id, enabled: enabled, scope: scope,
                                                now: clock(), reason: reason) else { return }
            player.begin(grant: grant.id) { [weak self] id, event in
                DispatchQueue.main.async { self?.playbackEvent(event, id: id) }
            }
        }
    }

    func receive(_ packet: Data, scope: VisionAudioScope) {
        storage.withLock { state in
            guard let grant = state.model.phase.grant, grant.scope == scope,
                  state.model.admits(grant, now: clock()) else { return }
            player.receive(packet, grant: grant.id)
        }
    }

    @discardableResult
    func sendIfPermitted(_ control: VisionAudioControl, _ body: () -> Void) -> Bool {
        storage.withLock { state in
            guard state.model.isCurrent(control.grant) else { return false }
            body()
            return true
        }
    }

    private func playbackEvent(_ event: VisionAudioPlaybackEvent, id: UUID) {
        change { model in
            guard let grant = model.phase.grant, grant.id == id else { return }
            switch event {
            case .rendering: _ = model.rendered(grant, now: clock())
            case .waiting: model.underrun(grant, now: clock())
            case .failed(let problem): model.stop(problem: problem)
            }
        }
    }

    private func change(_ body: (inout VisionAudioState) -> Void) {
        let result = storage.withLock { state -> (VisionAudioState, UInt64) in
            let previous = state.model.phase.grant
            body(&state.model)
            if let previous, state.model.phase.grant != previous {
                player.stop()
                send(VisionAudioControl(grant: previous, enabled: false))
            }
            state.revision &+= 1
            return (state.model, state.revision)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, result.1 > self.displayedRevision else { return }
            self.displayedRevision = result.1
            self.presentation = result.0
            self.deadline?.cancel()
            self.deadline = nil
            let until: Double
            switch result.0.phase {
            case .requesting(_, let expiry), .waiting(_, let expiry): until = expiry
            default: return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.change { model in _ = model.expire(now: self.clock()) }
            }
            self.deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until - self.clock()), execute: work)
        }
    }

}
