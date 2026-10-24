#if os(visionOS) || VISION_SENTRY_CHECKS
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    func bindVisionSentry(to peer: NWConnection?) {
        dispatchPrecondition(condition: .onQueue(.main))
        visionSentry.bind(peer.map(ObjectIdentifier.init), trusted: peer != nil && visionSentryTrusted,
                          identity: peer.flatMap { visionSentryIdentity($0) })
        publishVisionSentry()
    }

    func observeVisionSentry(_ list: WindowList, from peer: NWConnection) {
        guard connection === peer else { return }
        visionSentry.bind(ObjectIdentifier(peer), trusted: visionSentryTrusted, identity: visionSentryIdentity(peer))
        visionSentry.observe(list, from: ObjectIdentifier(peer))
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func receiveVisionSentry(_ data: Data, from peer: NWConnection) {
        guard connection === peer else { return }
        visionSentry.bind(ObjectIdentifier(peer), trusted: visionSentryTrusted, identity: visionSentryIdentity(peer))
        if let response = try? SentryControlResponse.decodePayload(data) {
            visionSentry.receiveControl(response, from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime)
        } else {
            guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any], fields["version"] == nil,
                  let response = Wire.decode(SentryResponse.self, from: data) else { return }
            visionSentry.receive(response, from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime)
        }
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func invalidateVisionSentryCatalog(from peer: NWConnection) {
        guard connection === peer else { return }
        visionSentry.invalidateCatalog(from: ObjectIdentifier(peer))
        DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
    }

    func activateVisionSentry() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard visionSentry.snapshot.state?.control == nil else { return }
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
        scheduleVisionSentryDeadline(activation.requestID)
    }

    func setVisionSentry(_ desired: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        if desired && visionSentry.snapshot.state?.control == nil { activateVisionSentry(); return }
        sendVisionSentryControl(desired: desired)
    }

    func readbackVisionSentry() {
        dispatchPrecondition(condition: .onQueue(.main))
        sendVisionSentryControl(desired: nil)
    }

    private func sendVisionSentryControl(desired: Bool?) {
        guard connected, visionSentryTrusted, let expected = connection,
              let identity = visionSentryIdentity(expected) else { return }
        visionSentry.bind(ObjectIdentifier(expected), trusted: true, identity: identity)
        let now = ProcessInfo.processInfo.systemUptime
        var requestID = UUID()
        let attemptID = UUID()
        let store = visionSentry.store
        var rawRequest: Data?
        let submission = SessionLink.Submission(deadline: now + VisionSentryController.timeout, isCurrent: { [weak self] in
            guard let rawRequest else { return false }
            return self?.visionSentryIdentity(expected, checkConnection: false) == identity &&
                store.contains(rawRequest: rawRequest, binding: identity)
        }) { [weak self] outcome in
            guard let self else { return }
            if outcome == .cancelled {
                self.visionSentry.timeout(requestID, now: ProcessInfo.processInfo.systemUptime, attemptID: attemptID)
                self.visionSentry.cancelled(requestID, attemptID: attemptID)
            }
            self.publishVisionSentry()
        }
        let link = visionSentryLink
        guard let request = visionSentry.beginControl(desired: desired, requestID: requestID, attemptID: attemptID, now: now,
            cancel: { link.cancel(submission) }) else { publishVisionSentry(); return }
        requestID = request.requestID
        rawRequest = request.rawRequest
        publishVisionSentry()
        let bytes = StreamMessage(kind: .activateSentry, timestamp: Date().timeIntervalSince1970,
            isKeyframe: false, payload: request.rawRequest).serialized()
        queue.async { [weak self] in
            guard let self, self.visionSentryIdentity(expected) == identity else { link.cancel(submission); return }
            _ = self.visionSentry.submitControl(request, to: ObjectIdentifier(expected), now: ProcessInfo.processInfo.systemUptime, attemptID: attemptID) {
                link.send(bytes, onlyOn: expected, submission: submission)
            }
            DispatchQueue.main.async { [weak self] in self?.publishVisionSentry() }
        }
        scheduleVisionSentryDeadline(request.requestID, attemptID: attemptID)
    }

    private func scheduleVisionSentryDeadline(_ requestID: UUID, attemptID: UUID? = nil) {
        visionSentryDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visionSentry.timeout(requestID, now: ProcessInfo.processInfo.systemUptime, attemptID: attemptID)
            self.publishVisionSentry()
        }
        visionSentryDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + VisionSentryController.timeout, execute: deadline)
    }

    private func visionSentryIdentity(_ peer: NWConnection, checkConnection: Bool = true) -> VisionSentryStoredRequest.Binding? {
        #if os(visionOS)
        guard connected, visionSentryTrusted, !checkConnection || connection === peer, let session, let id = session.macID,
              macInfoSaved, let verified = macInfoVerified, verified.info.macID == id,
              let saved = savedMac(id), let pin = saved.fingerprintData,
              verified.fingerprint == pin, RemoteTLS.peerFingerprint(peer) == pin,
              MacID.make(fingerprint: pin) == id,
              session.route.isRemote || session.home == .saved(pin: pin),
              let devicePin = DeviceIdentity.existing()?.fingerprint else { return nil }
        return .init(macID: id, hostFingerprint: pin, deviceFingerprint: devicePin)
        #else
        return (!checkConnection || connection === peer) && visionSentryTrusted ? sentryTestIdentity : nil
        #endif
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
