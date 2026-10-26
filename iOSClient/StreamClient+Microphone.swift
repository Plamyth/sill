#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import Network
import StreamProtocol

extension StreamClient {
    func toggleIPadMicrophone() {
        if microphoneCleanupProblem != nil {
            if microphonePhase.canStop { setDesiredAudio(.microphone, enabled: false) }
            retryMicrophoneCleanup()
            return
        }
        if microphonePhase.canStop || desiredAudio.selection.microphone {
            setDesiredAudio(.microphone, enabled: false)
            return
        }
        guard let context = audioForwardingContext else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allowed = await self.requestAudioRouteMicrophonePermission()
            guard allowed, !Task.isCancelled, self.audioForwardingContext == context else { return }
            self.setDesiredAudio(.microphone, enabled: true)
        }
    }

    func microphoneSetConnection(_ next: NWConnection?) {
        desiredAudioSetConnection(next)
        if microphonePolicy.peer != next.map(ObjectIdentifier.init) { audioRouteAuthorization = nil }
        recordMicrophoneDiagnostic("connection_observed", ["same": String(microphonePolicy.peer == next.map(ObjectIdentifier.init)), "connected": String(next != nil)])
        applyMicrophone(microphonePolicy.setConnection(next.map(ObjectIdentifier.init)))
    }

    func microphoneSourceWillChange() {
        suspendAudioForwarding()
        suspendDesiredAudio()
        desiredAudio.sourceWillChange()
        audioRouteAuthorization = nil
        recordMicrophoneDiagnostic("source_change", ["route": IPadMicrophoneDiagnostics.route()])
        applyMicrophone(microphonePolicy.sourceWillChange())
    }

    func microphoneBecameInactive() {
        suspendAudioForwarding(discardDraft: false)
        suspendDesiredAudio(preserveManualPermission: true)
        recordMicrophoneDiagnostic("inactive", ["route": IPadMicrophoneDiagnostics.route()])
        applyMicrophone(microphonePolicy.inactive())
    }

    func microphoneInterrupted() {
        suspendAudioForwarding()
        suspendDesiredAudio()
        audioRouteAuthorization = nil
        recordMicrophoneDiagnostic("interruption_or_route", ["route": IPadMicrophoneDiagnostics.route()])
        applyMicrophone(microphonePolicy.interrupted())
    }

    func microphoneBackgrounded() {
        suspendAudioForwarding()
        suspendDesiredAudio()
        audioRouteAuthorization = nil
        recordMicrophoneDiagnostic("background", ["route": IPadMicrophoneDiagnostics.route()])
        applyMicrophone(microphonePolicy.backgrounded())
    }

    func microphoneObserve(_ list: WindowList, from peer: NWConnection) {
        let previous = microphonePolicy.scope
        applyMicrophone(microphonePolicy.observe(list, from: ObjectIdentifier(peer)))
        if previous != microphonePolicy.scope { audioRouteAuthorization = nil }
    }

    func receiveMicrophone(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .microphoneState || header.kind == .microphoneReceipt else { return false }
        guard data.count <= MicrophoneWire.replyLimit else { return true }
        if header.kind == .microphoneState, let state = Wire.decode(MicrophoneState.self, from: data) {
            let arrived = DispatchTime.now().uptimeNanoseconds
            let admission = audioAdmission.ticket(for: ObjectIdentifier(peer))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === peer else { return }
                if state.phase == .active && !self.audioAdmission.isCurrent(admission) { return }
                IPadMicrophoneDiagnostics.shared.attempt(self.microphonePolicy.startRequestID ?? state.requestID)
                    .record("grant_phase_" + state.phase.rawValue, ["phaseBeforeCanStop": String(self.microphonePolicy.phase.canStop),
                        "grantPresent": String(state.grantID != nil), "reasonPresent": String(state.reason != nil),
                        "mainQueueDelayMilliseconds": String(Double(DispatchTime.now().uptimeNanoseconds - arrived) / 1_000_000)])
                self.applyMicrophone(self.microphonePolicy.receive(state, from: ObjectIdentifier(peer)))
                self.reconcileDesiredAudio()
            }
        } else if header.kind == .microphoneReceipt, let receipt = Wire.decode(MicrophoneReceipt.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connection === peer else { return }
                IPadMicrophoneDiagnostics.shared.received(.microphoneReceipt, hostTimestamp: header.timestamp)
                self.microphonePolicy.receive(receipt, from: ObjectIdentifier(peer))
                self.microphoneReceipt = self.microphonePolicy.latestReceipt
            }
        }
        return true
    }

    func applyMicrophone(_ effects: [IPadMicrophonePolicy.Effect], allowPermissionPrompt: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        observeAudioDiagnostics()
        defer { observeAudioDiagnostics() }
        var pendingStops: [(ObjectIdentifier, MicrophoneControl)] = []
        for effect in effects {
            switch effect {
            case .requestPermission(let peer, let scope, let request):
                guard desiredAudioPermits(.microphone) else {
                    applyMicrophone(microphonePolicy.permissionResolved(false, requestID: request, scope: scope, from: peer))
                    continue
                }
                let revision = desiredAudio.revision(for: .microphone)
                let diagnostics = IPadMicrophoneDiagnostics.shared.attempt(request)
                diagnostics.record("permission_requested", ["phaseCanStop": String(microphonePolicy.phase.canStop)])
                guard let c = connection, ObjectIdentifier(c) == peer else { continue }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.connection === c,
                          self.microphonePolicy.phase == .authorizing,
                          self.microphonePolicy.startRequestID == request,
                          self.microphonePolicy.scope == scope,
                          self.desiredAudio.revision(for: .microphone) == revision,
                          self.desiredAudioPermits(.microphone) else {
                        self.applyMicrophone(self.microphonePolicy.permissionResolved(false,
                            requestID: request, scope: scope, from: peer))
                        return
                    }
                    let allowed: Bool
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        allowed = true
                    } else if allowPermissionPrompt && IPadAudioSession.shared.microphoneAvailable {
                        allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    } else { allowed = false }
                    diagnostics.record("permission_result", ["allowed": String(allowed), "microphoneAvailable": String(IPadAudioSession.shared.microphoneAvailable), "phaseCanStop": String(self.microphonePolicy.phase.canStop)])
                    let finish: () -> Void = { [weak self] in
                        guard let self else { return }
                        guard self.connection === c, self.desiredAudioPermits(.microphone),
                              self.desiredAudio.revision(for: .microphone) == revision,
                              self.microphonePolicy.startRequestID == request else {
                            self.applyMicrophone(self.microphonePolicy.permissionResolved(false,
                                requestID: request, scope: scope, from: peer))
                            return
                        }
                        self.applyMicrophone(self.microphonePolicy.permissionResolved(allowed, requestID: request,
                            scope: scope, from: peer, microphoneAvailable: IPadAudioSession.shared.microphoneAvailable))
                    }
                    if allowPermissionPrompt && UIApplication.shared.applicationState == .inactive {
                        self.audioPendingMicrophonePermission = finish
                    } else { finish(); self.reconcileDesiredAudio() }
                }
            case .closeFrames:
                microphoneFrames.close()
            case .stopCapture:
                microphoneCaptureToken = nil
                if microphoneCleanupProblem == nil { retryMicrophoneCleanup() }
            case .send(let peer, let control):
                IPadMicrophoneDiagnostics.shared.attempt(microphonePolicy.startRequestID ?? control.requestID)
                    .record("control_" + control.operation.rawValue, ["phaseCanStop": String(microphonePolicy.phase.canStop)])
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
                let revision = desiredAudio.revision(for: .microphone)
                let diagnostics = IPadMicrophoneDiagnostics.shared.attempt(request)
                diagnostics.record("capture_begin_effect", ["scopeMatches": String(microphonePolicy.scope == scope), "capturePresent": String(microphoneCapture != nil), "cleanupProblem": String(microphoneCleanupProblem != nil)])
                guard let c = connection, ObjectIdentifier(c) == peer,
                      desiredAudioPermits(.microphone),
                      microphonePolicy.phase == .capturing,
                      microphonePolicy.startRequestID == request,
                      microphonePolicy.grantID == grant,
                      microphonePolicy.scope == scope,
                      microphoneCapture == nil, microphoneCleanupProblem == nil else {
                    diagnostics.record("capture_begin_skipped")
                    applyMicrophone(microphonePolicy.captureFailed(requestID: request, grant: grant, from: peer,
                        reason: "오디오 연결이나 화면 제어권이 바뀌어 마이크 시작을 취소했습니다."))
                    continue
                }
                let capture = IPadMicrophoneCapture(diagnostics: diagnostics)
                let captureID = UUID()
                microphoneCapture = capture
                microphoneCaptureToken = captureID
                let frames = microphoneFrames
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.microphoneCapture === capture,
                          self.microphoneCaptureToken == captureID,
                          self.microphonePolicy.phase == .capturing,
                          self.microphonePolicy.startRequestID == request,
                          self.microphonePolicy.grantID == grant,
                          self.microphonePolicy.scope == scope,
                          self.desiredAudio.revision(for: .microphone) == revision,
                          self.desiredAudioPermits(.microphone),
                          self.connection === c else {
                        self.applyMicrophone(self.microphonePolicy.captureFailed(requestID: request,
                            grant: grant, from: peer, reason: "마이크 시작 전에 연결 상태가 바뀌었습니다."))
                        return
                    }
                    do {
                        try await capture.start(emitBatch: { batch in frames.emitBatch(batch, captureID: captureID, diagnostics: diagnostics) })
                        guard self.microphoneCapture === capture,
                              self.microphoneCaptureToken == captureID,
                              self.microphonePolicy.phase == .capturing,
                              self.microphonePolicy.startRequestID == request,
                              self.microphonePolicy.grantID == grant,
                              self.microphonePolicy.scope == scope,
                              self.desiredAudio.revision(for: .microphone) == revision,
                              self.desiredAudioPermits(.microphone),
                              self.connection === c else {
                            do { try capture.stop() }
                            catch { self.recordMicrophoneCleanup(capture, error: error) }
                            if self.microphoneCapture === capture && self.microphoneCleanupProblem == nil {
                                self.microphoneCapture = nil
                                self.microphoneCaptureToken = nil
                            }
                            self.applyMicrophone(self.microphonePolicy.captureFailed(requestID: request,
                                grant: grant, from: peer, reason: "마이크 시작 중 연결 상태가 바뀌었습니다."))
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
                      desiredAudioPermits(.microphone),
                      microphonePolicy.phase == .live,
                      microphonePolicy.scope == scope, microphonePolicy.grantID == grant,
                      let captureID = microphoneCaptureToken else { continue }
                microphoneFrames.open(connection: c, scope: scope, grant: grant, captureID: captureID,
                    admission: audioCatalogAdmission, diagnostics: microphonePolicy.startRequestID.map { IPadMicrophoneDiagnostics.shared.attempt($0) })
            }
        }
        for (peer, control) in pendingStops { sendMicrophoneControl(control, to: peer) }
        if microphonePhase != microphonePolicy.phase { microphonePhase = microphonePolicy.phase }
        if microphonePhase != .live { microphoneReceipt = nil }
    }

    private func recordMicrophoneDiagnostic(_ event: String, _ fields: [String: String] = [:]) {
        guard let request = microphonePolicy.startRequestID else { return }
        var values = fields
        values["phaseCanStop"] = String(microphonePolicy.phase.canStop)
        IPadMicrophoneDiagnostics.shared.attempt(request).record(event, values)
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
        if control.operation == .start && !desiredAudioPermits(.microphone) { return }
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
