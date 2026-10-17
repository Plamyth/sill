#if os(iOS)
import Foundation
import AVFoundation
import Network
import StreamProtocol

extension StreamClient {
    func toggleIPadMicrophone() {
        if microphoneCleanupProblem != nil {
            retryMicrophoneCleanup()
            return
        }
        applyMicrophone(microphonePolicy.toggle())
    }

    func microphoneSetConnection(_ next: NWConnection?) {
        applyMicrophone(microphonePolicy.setConnection(next.map(ObjectIdentifier.init)))
    }

    func microphoneSourceWillChange() {
        applyMicrophone(microphonePolicy.sourceWillChange())
    }

    func microphoneBecameInactive() {
        applyMicrophone(microphonePolicy.inactive())
    }

    func microphoneInterrupted() {
        applyMicrophone(microphonePolicy.interrupted())
    }

    func microphoneBackgrounded() {
        applyMicrophone(microphonePolicy.backgrounded())
    }

    func microphoneObserve(_ list: WindowList, from peer: NWConnection) {
        applyMicrophone(microphonePolicy.observe(list, from: ObjectIdentifier(peer)))
    }

    func receiveMicrophone(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .microphoneState || header.kind == .microphoneReceipt else { return false }
        guard data.count <= MicrophoneWire.replyLimit else { return true }
        if header.kind == .microphoneState, let state = Wire.decode(MicrophoneState.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === peer else { return }
                self.applyMicrophone(self.microphonePolicy.receive(state, from: ObjectIdentifier(peer)))
            }
        } else if header.kind == .microphoneReceipt, let receipt = Wire.decode(MicrophoneReceipt.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === peer else { return }
                self.microphonePolicy.receive(receipt, from: ObjectIdentifier(peer))
                self.microphoneReceipt = self.microphonePolicy.latestReceipt
            }
        }
        return true
    }

    private func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect]) {
        dispatchPrecondition(condition: .onQueue(.main))
        var pendingStops: [(ObjectIdentifier, MicrophoneControl)] = []
        for effect in effects {
            switch effect {
            case .requestPermission(let peer, let scope, let request):
                guard let c = connection, ObjectIdentifier(c) == peer else { continue }
                Task { @MainActor [weak self] in
                    guard let self, self.connection === c,
                          self.microphonePolicy.phase == .authorizing,
                          self.microphonePolicy.startRequestID == request,
                          self.microphonePolicy.scope == scope else { return }
                    let allowed: Bool
                    if IPadAudioSession.shared.microphoneAvailable {
                        allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    } else { allowed = true }
                    guard self.connection === c else { return }
                    self.applyMicrophone(self.microphonePolicy.permissionResolved(allowed, requestID: request,
                        scope: scope, from: peer, microphoneAvailable: IPadAudioSession.shared.microphoneAvailable))
                }
            case .closeFrames:
                microphoneFrames.close()
            case .stopCapture:
                microphoneCaptureToken = nil
                retryMicrophoneCleanup()
            case .send(let peer, let control):
                if control.operation == .stop {
                    pendingStops.append((peer, control))
                } else {
                    sendMicrophoneControl(control, to: peer)
                }
                if control.operation == .start {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self else { return }
                        self.applyMicrophone(self.microphonePolicy.startTimedOut(control.requestID, from: peer))
                    }
                } else if control.operation == .stop {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self else { return }
                        self.applyMicrophone(self.microphonePolicy.stopTimedOut(control.requestID, from: peer))
                    }
                }
            case .beginCapture(let peer, let scope, let request, let grant):
                guard let c = connection, ObjectIdentifier(c) == peer,
                      microphonePolicy.scope == scope,
                      microphoneCapture == nil, microphoneCleanupProblem == nil else { continue }
                let capture = IPadMicrophoneCapture()
                let captureID = UUID()
                microphoneCapture = capture
                microphoneCaptureToken = captureID
                let frames = microphoneFrames
                Task { @MainActor [weak self] in
                    guard let self, self.microphoneCapture === capture,
                          self.microphoneCaptureToken == captureID,
                          self.microphonePolicy.phase == .capturing,
                          self.microphonePolicy.startRequestID == request,
                          self.microphonePolicy.grantID == grant,
                          self.microphonePolicy.scope == scope,
                          self.connection === c else { return }
                    do {
                        try await capture.start(emitBatch: { batch in frames.emitBatch(batch, captureID: captureID) })
                        guard self.microphoneCapture === capture,
                              self.microphoneCaptureToken == captureID,
                              self.connection === c else {
                            do { try capture.stop() }
                            catch { self.recordMicrophoneCleanup(capture, error: error) }
                            return
                        }
                        self.applyMicrophone(self.microphonePolicy.captureStarted(requestID: request,
                                                                                 grant: grant, from: peer))
                    } catch {
                        let startError = error
                        do { try capture.stop() }
                        catch { self.recordMicrophoneCleanup(capture, error: error) }
                        guard self.microphoneCapture === capture else { return }
                        if self.microphoneCleanupProblem == nil { self.microphoneCapture = nil }
                        if self.microphonePolicy.phase == .capturing {
                            self.applyMicrophone(self.microphonePolicy.captureFailed(requestID: request,
                                                                                    grant: grant, from: peer,
                                                                                    reason: startError.localizedDescription))
                        }
                    }
                }
            case .openFrames(let peer, let scope, let grant):
                guard let c = connection, ObjectIdentifier(c) == peer,
                      let captureID = microphoneCaptureToken else { continue }
                microphoneFrames.open(connection: c, scope: scope, grant: grant, captureID: captureID)
            }
        }
        for (peer, control) in pendingStops { sendMicrophoneControl(control, to: peer) }
        if microphonePhase != microphonePolicy.phase { microphonePhase = microphonePolicy.phase }
        if microphonePhase != .live { microphoneReceipt = nil }
    }

    func requestMicrophoneReceipt() {
        guard microphonePolicy.phase == .live, let connection,
              microphonePolicy.peer == ObjectIdentifier(connection),
              let scope = microphonePolicy.scope, let grant = microphonePolicy.grantID else { return }
        sendMicrophoneControl(MicrophoneControl(operation: .receipt, requestID: UUID(),
                                               scope: scope, grantID: grant), to: ObjectIdentifier(connection))
    }

    private func sendMicrophoneControl(_ control: MicrophoneControl, to peer: ObjectIdentifier) {
        guard let c = connection, ObjectIdentifier(c) == peer else { return }
        let message = StreamMessage(kind: .microphoneControl, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Wire.encode(control))
        c.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if let error { self?.connectionLost(c, error: error) }
        })
    }

    private func retryMicrophoneCleanup() {
        guard let capture = microphoneCapture else { return }
        do {
            try capture.stop()
            microphoneCapture = nil
            microphoneCaptureToken = nil
            microphoneCleanupProblem = nil
        } catch {
            recordMicrophoneCleanup(capture, error: error)
        }
    }

    private func recordMicrophoneCleanup(_ capture: IPadMicrophoneCapture, error: Error) {
        guard microphoneCapture == nil || microphoneCapture === capture else { return }
        microphoneCapture = capture
        microphoneCleanupProblem = "오디오 세션 정리가 필요합니다. 탭해서 다시 시도하세요. \(error.localizedDescription)"
    }
}
#endif
