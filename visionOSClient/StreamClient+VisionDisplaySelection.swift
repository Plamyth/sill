#if os(visionOS) || VISION_DISPLAY_CHECKS
import Foundation
import Network
import StreamProtocol
#if os(visionOS)
import UIKit
#endif

extension StreamClient {
    func visionDisplayApplicationIsActive() -> Bool {
        #if os(visionOS)
        return UIApplication.shared.applicationState == .active
        #else
        return visionDisplayApplicationActive
        #endif
    }

    func bindVisionDisplays(to peer: NWConnection?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard visionDisplayPeer !== peer else { return }
        cancelVisionDisplaySelection(.peerChanged)
        visionDisplayPeer = peer
        visionDisplaySelection.bind(peerEpoch: peer == nil ? nil : UUID())
    }

    func admitVisionDisplays(lease: VisionWindowLease?, foreground: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionDisplaySelection.admit(lease: lease, foreground: foreground && visionDisplayApplicationIsActive())
        reconcileVisionDisplaySubmission()
    }

    func setVisionDisplayModal(_ shown: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionDisplaySelection.setModal(shown)
        if shown {
            visionInputSession?.allowed = false
            revokeVisionTextDrafts()
            microphoneSourceWillChange()
            visionAudio.stop()
        }
    }

    func observeVisionDisplays(_ list: WindowList, from peer: NWConnection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connection === peer else { return }
        bindVisionDisplays(to: peer)
        visionDisplaySelection.observe(.init(list))
        confirmVisionDisplayPresentation()
        reconcileVisionDisplaySubmission()
    }

    func confirmVisionDisplayPresentation() {
        dispatchPrecondition(condition: .onQueue(.main))
        if case .presented(let epoch) = visionInputBinding { visionDisplaySelection.presented(epoch) }
        reconcileVisionDisplaySubmission()
    }

    @discardableResult
    func selectVisionDisplay(_ command: VisionDisplaySelection.Command) -> VisionDisplaySelection.Result {
        dispatchPrecondition(condition: .onQueue(.main))
        if !visionDisplayApplicationIsActive() {
            admitVisionDisplays(lease: visionDisplaySelection.lease, foreground: false)
        }
        let known = visionDisplaySelection.known(command.requestID)
        let result = visionDisplaySelection.begin(command)
        guard !known, result.code == .releasing else { return result }
        guard let expected = connection, expected === visionDisplayPeer else {
            cancelVisionDisplaySelection(.peerChanged); return visionDisplaySelection.lastResult ?? result
        }
        visionInputSession?.allowed = false
        revokeVisionTextDrafts()
        visionInputSession?.releaseAll()
        microphoneSourceWillChange()
        visionAudio.stop()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visionDisplaySelection.timeout(command.requestID)
            self.reconcileVisionDisplaySubmission()
        }
        visionDisplayDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        afterVisionInputRelease { [weak self] confirmed in
            guard let self, self.visionDisplaySelection.pending?.command == command else { return }
            guard self.connection === expected, self.visionDisplayPeer === expected else {
                self.cancelVisionDisplaySelection(.peerChanged); return
            }
            guard self.visionDisplayApplicationIsActive() else {
                self.admitVisionDisplays(lease: self.visionDisplaySelection.lease, foreground: false)
                return
            }
            guard self.visionDisplaySelection.released(command.requestID, confirmed: confirmed) else {
                self.reconcileVisionDisplaySubmission(); return
            }
            let submission = SessionLink.Submission { [weak self] outcome in
                guard let self, self.visionDisplaySelection.pending?.command == command else { return }
                switch outcome {
                case .submitted: self.visionDisplaySelection.submitted(command.requestID)
                case .cancelled: self.visionDisplaySelection.cancel(.sendCancelled)
                }
                self.reconcileVisionDisplaySubmission()
            }
            self.visionDisplaySubmission = submission
            let selection = DisplaySelection(displayID: command.displayID, inventoryID: command.token.inventory)
            let bytes = StreamMessage(kind: .selectDisplay, timestamp: Date().timeIntervalSince1970,
                                      isKeyframe: false, payload: Wire.encode(selection)).serialized()
            _ = self.visionDisplayLink.send(bytes, onlyOn: expected, submission: submission)
        }
        return result
    }

    func cancelVisionDisplaySelection(_ reason: VisionDisplaySelection.Code = .cancelled) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionDisplaySelection.cancel(reason)
        reconcileVisionDisplaySubmission()
    }

    private func reconcileVisionDisplaySubmission() {
        guard visionDisplaySelection.pending == nil else { return }
        visionDisplayDeadline?.cancel(); visionDisplayDeadline = nil
        if let submission = visionDisplaySubmission {
            visionDisplaySubmission = nil
            visionDisplayLink.cancel(submission)
        }
    }
}
#endif
