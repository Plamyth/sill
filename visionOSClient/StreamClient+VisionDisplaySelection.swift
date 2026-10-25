#if os(visionOS) || VISION_DISPLAY_CHECKS
import Foundation
import Network
import StreamProtocol
#if os(visionOS)
import UIKit
#endif

extension StreamClient {
    @discardableResult
    func selectAdjacentVisionDisplay(by step: Int, expected: VisionDisplaySelection.Token) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let command = visionDisplaySelection.adjacentCommand(by: step, expected: expected) else { return false }
        return selectVisionDisplay(command).code == .releasing
    }

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
        #if os(visionOS)
        if foreground && lease != nil { ownerEnrollmentTrustChanged() }
        else { cancelOwnerEnrollment() }
        #endif
        reconcileVisionDisplaySubmission()
        reconcileVisionAutomaticDisplay()
    }

    func setVisionDisplayModal(_ shown: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionDisplaySelection.setModal(shown)
        reconcileVisionDisplaySubmission()
        if !shown { reconcileVisionAutomaticDisplay() }
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
        reconcileVisionAutomaticDisplay()
    }

    func invalidateVisionDisplayCatalog(from peer: NWConnection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connection === peer else { return }
        visionDisplaySelection.invalidateCatalog()
        reconcileVisionDisplaySubmission()
    }

    func confirmVisionDisplayPresentation() {
        dispatchPrecondition(condition: .onQueue(.main))
        if case .presented(let epoch) = visionInputBinding {
            visionDisplaySelection.presented(epoch, macID: visionAutomaticDisplayMacID)
            if let macID = visionAutomaticDisplayMacID {
                visionDisplaySelection.recoverAutomaticPresentation(epoch, macID: macID)
            }
        }
        reconcileVisionDisplaySubmission()
    }

    private var visionAutomaticDisplayMacID: String? {
        guard let peer = connection, peer === visionDisplayPeer,
              authenticatedVisionMacAudioPeer == ObjectIdentifier(peer) else { return nil }
        return session?.macID
    }

    func reconcileVisionAutomaticDisplay() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let macID = visionAutomaticDisplayMacID else {
            if visionDisplaySelection.hasAutomaticOpportunity {
                visionDisplaySelection.stopAutomatic()
                reconcileVisionDisplaySubmission()
            }
            return
        }
        if let command = visionDisplaySelection.automaticCommand(macID: macID) {
            _ = selectVisionDisplay(command)
        }
        reconcileVisionDisplaySubmission()
    }

    func prepareVisionManualSource() {
        dispatchPrecondition(condition: .onQueue(.main))
        visionDisplaySelection.prepareManualSource()
        reconcileVisionDisplaySubmission()
    }

    @discardableResult
    func selectVisionDisplay(_ command: VisionDisplaySelection.Command) -> VisionDisplaySelection.Result {
        dispatchPrecondition(condition: .onQueue(.main))
        if !visionDisplayApplicationIsActive() {
            admitVisionDisplays(lease: visionDisplaySelection.lease, foreground: false)
        }
        if command.automaticRevision == nil {
            visionDisplaySelection.stopAutomatic()
            reconcileVisionDisplaySubmission()
        }
        let known = visionDisplaySelection.known(command.requestID)
        #if os(visionOS)
        let presented = connection === visionDisplayPeer ? visionPresentedPeerEpoch : nil
        let result = visionDisplaySelection.begin(command, presented: presented, macID: visionAutomaticDisplayMacID)
        #else
        let result = visionDisplaySelection.begin(command)
        #endif
        guard !known, result.code == .releasing else { return result }
        guard let expected = connection, expected === visionDisplayPeer else {
            cancelVisionDisplaySelection(.peerChanged); return visionDisplaySelection.lastResult ?? result
        }
        #if os(visionOS)
        prepareVisionPeerSourceChange(.display(command.displayID))
        #endif
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
            if command.automaticRevision != nil {
                guard let macID = self.visionAutomaticDisplayMacID,
                      self.visionDisplaySelection.automaticIsCurrent(command, macID: macID) else {
                    self.cancelVisionDisplaySelection(.staleScope); return
                }
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
            let selection = DisplaySelection(displayID: command.displayID, inventoryID: command.token.inventory,
                                             origin: command.automaticRevision == nil ? .human : .automatic,
                                             selectionRevision: command.automaticRevision)
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
