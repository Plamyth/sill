#if os(visionOS) || VISION_SENTRY_CHECKS
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func bindVisionSentry(to peer: NWConnection?) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionSentry.bind(peer.map(ObjectIdentifier.init), trusted: peer != nil && visionSentryTrusted)
        publishVisionSentry()
    }

    func observeVisionSentry(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        visionSentry.observe(list, from: ObjectIdentifier(peer))
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func receiveVisionSentry(_ data: Data, from peer: NWConnection) {
        guard connection === peer, let response = Wire.decode(SentryResponse.self, from: data) else { return }
        visionSentry.receive(response, from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func invalidateVisionSentryCatalog(from peer: NWConnection) {
        guard connection === peer else { return }
        visionSentry.invalidateCatalog(from: ObjectIdentifier(peer))
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func activateVisionSentry() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connected, visionSentryTrusted, let expected = connection else { return }
        let requestID = UUID()
        let now = ProcessInfo.processInfo.systemUptime
        let submission = SessionLink.Submission(deadline: now + VisionSentryController.timeout) { [weak self] outcome in
            guard let self else { return }
            if outcome == .cancelled {
                self.visionSentry.timeout(requestID, now: ProcessInfo.processInfo.systemUptime)
                self.visionSentry.cancelled(requestID)
            }
            self.publishVisionSentry()
        }
        let link = visionSentryLink
        guard let activation = visionSentry.begin(requestID: requestID, now: now,
                                                  cancel: { link.cancel(submission) }) else { return }
        publishVisionSentry()
        let bytes = StreamMessage(kind: .activateSentry, timestamp: Date().timeIntervalSince1970,
                                  isKeyframe: false, payload: Wire.encode(activation)).serialized()
        queue.async { [weak self] in
            guard let self else { link.cancel(submission); return }
            _ = self.visionSentry.submit(activation, to: ObjectIdentifier(expected),
                                         now: ProcessInfo.processInfo.systemUptime) {
                link.send(bytes, onlyOn: expected, submission: submission)
            }
            DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visionSentry.timeout(activation.requestID, now: ProcessInfo.processInfo.systemUptime)
            self.publishVisionSentry()
        }
        visionSentryDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + VisionSentryController.timeout, execute: deadline)
    }

    func publishVisionSentry() {
        dispatchPrecondition(condition: .onQueue(.main))
        visionSentrySnapshot = visionSentry.snapshot
        if visionSentrySnapshot.pendingID == nil {
            visionSentryDeadline?.cancel(); visionSentryDeadline = nil
        }
    }
}
#endif
