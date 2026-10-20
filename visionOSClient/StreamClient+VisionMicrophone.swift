#if os(visionOS) || VISION_MICROPHONE_CHECKS
import Foundation
import Network
import StreamProtocol
#if os(visionOS)
import AVFoundation
#endif

/// Presentation admission is independent of the microphone lifecycle. Inactive may be the
/// system permission sheet; a released lease or background never preserves consent.
struct VisionMicrophoneAdmission {
    enum Scene: Equatable { case active, inactive, background }
    var lease: VisionWindowLease?
    var scene: Scene = .background
    var applicationActive = false
    var active: Bool { lease != nil && scene == .active && applicationActive }
}

struct VisionMicrophoneAuthorization {
    enum Result { case pending, resolved(Bool), cancelled }
    let connection: NWConnection
    let lease: VisionWindowLease
    let scope: MicrophoneScope
    let requestID: UUID
    var result: Result = .pending
}

extension StreamClient {
    #if os(visionOS)
    static func requestVisionRecordPermission(_ completion: @escaping (Bool) -> Void) {
        guard !VisionReleaseTestContext.isTestBundle else { completion(false); return }
        Task { @MainActor in completion(await AVAudioApplication.requestRecordPermission()) }
    }
    #endif

    var visionMicrophoneCanStart: Bool {
        #if os(visionOS)
        if VisionReleaseTestContext.isTestBundle || visionDisplaySelection.inputBlocked { return false }
        #endif
        return microphoneAdmission.active && microphoneAuthorization == nil && microphonePolicy.canStart &&
            microphoneCapture == nil && microphoneCleanupProblem == nil &&
            VisionAudioSharedHardware.shared.cleanupProblem == nil
    }

    func requestVisionMicrophoneReceipt() {
        guard microphoneAdmission.active, microphoneCleanupProblem == nil, microphonePolicy.phase == .live,
              let c = connection, microphonePolicy.peer == ObjectIdentifier(c),
              let scope = microphonePolicy.scope, let grant = microphonePolicy.grantID else { return }
        sendMicrophoneControl(MicrophoneControl(operation: .receipt, requestID: UUID(),
            scope: scope, grantID: grant), to: ObjectIdentifier(c))
    }

    func stopVisionMicrophoneActual() {
        invalidateMicrophoneAuthorization()
        applyMicrophone(microphonePolicy.backgrounded())
    }

    #if os(visionOS)
    func startVisionMicrophoneAutomatically() {
        guard visionMicrophoneCanStart, AVAudioApplication.shared.recordPermission == .granted else { return }
        applyMicrophone(microphonePolicy.toggle(), automatic: true)
    }
    #endif

    func toggleVisionMicrophone() {
        if microphoneCleanupProblem != nil {
            retryMicrophoneCleanup(explicit: true)
            return
        }
        guard microphonePolicy.phase.canStop || visionMicrophoneCanStart else { return }
        applyMicrophone(microphonePolicy.toggle())
    }

    func microphoneSetConnection(_ next: NWConnection?) {
        if microphonePolicy.peer != next.map(ObjectIdentifier.init) { invalidateMicrophoneAuthorization() }
        applyMicrophone(microphonePolicy.setConnection(next.map(ObjectIdentifier.init)))
    }

    func microphoneSourceWillChange() {
        #if os(visionOS)
        visionAudioIntentWithdrawing = true
        #endif
        invalidateMicrophoneAuthorization()
        applyMicrophone(microphonePolicy.sourceWillChange())
        #if os(visionOS)
        VisionRemoteAudioStore.shared.refresh()
        #endif
    }

    func microphoneBackgrounded() {
        microphoneAdmission.applicationActive = false
        invalidateMicrophoneAuthorization()
        applyMicrophone(microphonePolicy.backgrounded())
    }

    func microphoneApplicationActive(_ active: Bool) {
        microphoneAdmission.applicationActive = active
        if active { consumeMicrophoneAuthorization() }
        else { applyMicrophone(microphonePolicy.inactive()) }
    }

    func microphoneSceneChanged(lease: VisionWindowLease?, scene: VisionMicrophoneAdmission.Scene) {
        let lostLease = microphoneAdmission.lease != lease
        microphoneAdmission.lease = lease
        microphoneAdmission.scene = scene
        if lostLease || lease == nil || scene == .background {
            invalidateMicrophoneAuthorization()
            applyMicrophone(microphonePolicy.backgrounded())
        } else if scene == .inactive {
            applyMicrophone(microphonePolicy.inactive())
        }
        if scene == .active { consumeMicrophoneAuthorization() }
        #if os(visionOS)
        VisionRemoteAudioStore.shared.refresh()
        #endif
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

    /// Cancelled OS requests retain their slot until the original completion drains.
    private func invalidateMicrophoneAuthorization() {
        guard var authorization = microphoneAuthorization else { return }
        switch authorization.result {
        case .pending, .cancelled:
            authorization.result = .cancelled
            microphoneAuthorization = authorization
        case .resolved:
            microphoneAuthorization = nil
        }
    }

    private func consumeMicrophoneAuthorization() {
        guard let authorization = microphoneAuthorization,
              case .resolved(let allowed) = authorization.result,
              microphoneAdmission.active else { return }
        guard microphoneAuthorizationIsCurrent(authorization) else {
            invalidateMicrophoneAuthorization()
            applyMicrophone(microphonePolicy.backgrounded())
            return
        }
        microphoneAuthorization = nil
        #if os(visionOS)
        guard VisionRemoteAudioStore.shared.permits(self, direction: .microphone) else {
            applyMicrophone(microphonePolicy.backgrounded())
            return
        }
        #endif
        applyMicrophone(microphonePolicy.permissionResolved(allowed, requestID: authorization.requestID,
            scope: authorization.scope, from: ObjectIdentifier(authorization.connection),
            microphoneAvailable: microphoneCapture == nil && microphoneCleanupProblem == nil &&
                VisionAudioSharedHardware.shared.cleanupProblem == nil))
    }

    private func microphoneAuthorizationIsCurrent(_ authorization: VisionMicrophoneAuthorization) -> Bool {
        connection === authorization.connection && microphoneAdmission.lease == authorization.lease &&
            microphonePolicy.peer == ObjectIdentifier(authorization.connection) &&
            microphonePolicy.scope == authorization.scope && microphonePolicy.phase == .authorizing &&
            microphonePolicy.startRequestID == authorization.requestID
    }

    private func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect], automatic: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let authorization = microphoneAuthorization, !microphoneAuthorizationIsCurrent(authorization) {
            invalidateMicrophoneAuthorization()
        }
        var pendingStops: [(ObjectIdentifier, MicrophoneControl)] = []
        for effect in effects {
            switch effect {
            case .requestPermission(let peer, let scope, let request):
                guard microphoneAuthorization == nil, microphoneAdmission.active,
                      let lease = microphoneAdmission.lease, let c = connection,
                      ObjectIdentifier(c) == peer else { continue }
                #if os(visionOS)
                if !automatic, !VisionRemoteAudioStore.shared.beginPermission(visionAudioOwnerID) {
                    applyMicrophone(microphonePolicy.backgrounded())
                    continue
                }
                #endif
                microphoneAuthorization = VisionMicrophoneAuthorization(connection: c, lease: lease,
                    scope: scope, requestID: request)
                #if os(visionOS)
                if automatic {
                    microphoneAuthorization?.result = .resolved(AVAudioApplication.shared.recordPermission == .granted)
                    consumeMicrophoneAuthorization()
                    continue
                }
                #endif
                #if os(visionOS)
                let permissionOwner = visionAudioOwnerID
                #endif
                requestVisionMicrophonePermission { [weak self] allowed in
                    DispatchQueue.main.async {
                        #if os(visionOS)
                        defer { VisionRemoteAudioStore.shared.endPermission(permissionOwner) }
                        #endif
                        guard let self, var authorization = self.microphoneAuthorization,
                              authorization.connection === c, authorization.requestID == request else { return }
                        switch authorization.result {
                        case .cancelled: self.microphoneAuthorization = nil
                        case .pending:
                            authorization.result = .resolved(allowed)
                            self.microphoneAuthorization = authorization
                            self.consumeMicrophoneAuthorization()
                        case .resolved: break
                        }
                    }
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
                #if os(visionOS)
                guard VisionRemoteAudioStore.shared.permits(self, direction: .microphone) else {
                    applyMicrophone(microphonePolicy.backgrounded())
                    continue
                }
                #endif
                guard microphoneAdmission.active,
                      let lease = microphoneAdmission.lease,
                      let c = connection, ObjectIdentifier(c) == peer,
                      microphonePolicy.scope == scope,
                      microphoneCapture == nil, microphoneCleanupProblem == nil,
                      VisionAudioSharedHardware.shared.cleanupProblem == nil else {
                    applyMicrophone(microphonePolicy.backgrounded())
                    continue
                }
                let captureID = UUID()
                let frames = microphoneFrames
                let capture = VisionMicrophoneCapture(hardware: VisionAudioSharedHardware.shared,
                    owner: visionAudioOwnerID, permitted: { [weak self] in
                        guard let self else { return false }
                        #if os(visionOS)
                        guard VisionRemoteAudioStore.shared.permits(self, direction: .microphone) else { return false }
                        #endif
                        return self.microphoneAdmission.active && self.microphoneAdmission.lease == lease &&
                            self.microphoneCaptureToken == captureID && self.connection === c &&
                            self.microphonePolicy.scope == scope && self.microphonePolicy.startRequestID == request &&
                            self.microphonePolicy.grantID == grant &&
                            (self.microphonePolicy.phase == .capturing || self.microphonePolicy.phase == .live)
                    }, closeFrames: { frames.close(captureID: captureID) }, failed: { [weak self] reason in
                        DispatchQueue.main.async {
                            guard let self, self.microphoneCaptureToken == captureID, self.connection === c else { return }
                            self.applyMicrophone(self.microphonePolicy.captureFailed(requestID: request,
                                grant: grant, from: peer, reason: reason))
                        }
                    })
                microphoneCapture = capture
                microphoneCaptureToken = captureID
                Task { @MainActor [weak self] in
                    guard let self, self.microphoneCapture === capture,
                          self.microphoneCaptureToken == captureID,
                          self.microphonePolicy.phase == .capturing,
                          self.microphonePolicy.startRequestID == request,
                          self.microphonePolicy.grantID == grant,
                          self.microphonePolicy.scope == scope,
                          self.connection === c else { return }
                    guard self.microphoneAdmission.active, self.microphoneAdmission.lease == lease else {
                        self.applyMicrophone(self.microphonePolicy.backgrounded())
                        return
                    }
                    do {
                        try await capture.start { batch in frames.emitBatch(batch, captureID: captureID) }
                        guard self.microphoneCapture === capture,
                              self.microphoneCaptureToken == captureID,
                              self.connection === c else {
                            do { try capture.stop() }
                            catch { self.recordMicrophoneCleanup(capture, error: error) }
                            return
                        }
                        guard self.microphoneAdmission.active, self.microphoneAdmission.lease == lease else {
                            self.applyMicrophone(self.microphonePolicy.backgrounded())
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
                guard microphoneAdmission.active else {
                    applyMicrophone(microphonePolicy.backgrounded())
                    continue
                }
                guard microphonePolicy.phase == .live,
                      microphonePolicy.scope == scope, microphonePolicy.grantID == grant,
                      microphoneCleanupProblem == nil,
                      let c = connection, ObjectIdentifier(c) == peer,
                      let captureID = microphoneCaptureToken else { continue }
                microphoneFrames.open(connection: c, scope: scope, grant: grant, captureID: captureID)
            }
        }
        for (peer, control) in pendingStops { sendMicrophoneControl(control, to: peer) }
        if microphonePhase != microphonePolicy.phase { microphonePhase = microphonePolicy.phase }
        if microphoneReceipt != microphonePolicy.latestReceipt { microphoneReceipt = microphonePolicy.latestReceipt }
    }

    private func sendMicrophoneControl(_ control: MicrophoneControl, to peer: ObjectIdentifier) {
        guard let c = connection, ObjectIdentifier(c) == peer else { return }
        let message = StreamMessage(kind: .microphoneControl, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Wire.encode(control))
        c.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if let error { self?.connectionLost(c, error: error) }
        })
    }

    private func retryMicrophoneCleanup(explicit: Bool = false) {
        guard let capture = microphoneCapture else { return }
        do {
            if explicit { try capture.retryCleanup() } else { try capture.stop() }
            microphoneCapture = nil
            microphoneCaptureToken = nil
            microphoneCleanupProblem = nil
        } catch {
            recordMicrophoneCleanup(capture, error: error)
        }
    }

    private func recordMicrophoneCleanup(_ capture: VisionMicrophoneCapture, error: Error) {
        guard microphoneCapture == nil || microphoneCapture === capture else { return }
        microphoneCapture = capture
        microphoneCleanupProblem = "오디오 세션 정리가 필요합니다. 탭해서 다시 시도하세요. \(error.localizedDescription)"
    }
}
#endif
