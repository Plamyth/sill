import Foundation
import StreamProtocol

// Native media is authorized only by a read back of this connection's submitted binding.
struct VisionAudioForwarding {
    typealias Desire = VisionRemoteAudioIntent.Desire
    struct Pending {
        let control: AudioForwardingControl
        let connection: UUID
    }
    let connection: UUID
    let device: AudioForwardingDeviceID
    private(set) var catalog: AudioForwardingCatalog?
    private(set) var snapshot: AudioForwardingSnapshot?
    private(set) var pending: Pending?
    private(set) var submitted: AudioForwardingIntentRequest?
    private(set) var problem: String?
    private var selection: Desire?
    private var resumed = false
    private var recoveryUsed = false
    private var preparationReads = 0
    private var needsObservation = true
    private var failed = false

    init(connection: UUID, device: AudioForwardingDeviceID) {
        self.connection = connection
        self.device = device
    }

    var binding: AudioForwardingBinding? {
        guard !failed, selection == nil, let request = submitted,
              let intent = snapshot?.intent, let binding = snapshot?.binding,
              intent.pairedDeviceId == device, intent.intentId == request.intentId,
              intent.intentRevision == request.intentRevision,
              intent.inputDesired == request.inputDesired, intent.outputDesired == request.outputDesired,
              binding.transportKind == .native, binding.transportId == request.transportId,
              binding.phase == .active else { return nil }
        return binding
    }
    func permits(_ direction: VisionRemoteAudioIntent.Direction) -> Bool {
        binding != nil && (direction == .microphone ? submitted?.inputDesired : submitted?.outputDesired) == true
    }
    var shouldObserve: Bool { !failed && (submitted != nil || needsObservation || selection != nil) }

    mutating func select(_ desire: Desire) {
        selection = desire
        recoveryUsed = false
        problem = nil
        failed = false
        needsObservation = true
    }
    mutating func suspend() {
        submitted = nil
        resumed = false
        needsObservation = true
        preparationReads = 0
    }
    mutating func fail(_ message: String) {
        failed = true
        submitted = nil
        pending = nil
        problem = message
    }
    mutating func preparationTimedOut(_ transport: UUID) {
        guard submitted?.transportId == transport, binding == nil else { return }
        fail("음성 연결 준비가 끝나지 않아 오디오를 중지했습니다. 다시 선택해 주세요.")
    }
    mutating func timeout(_ request: UUID) {
        guard pending?.control.requestID == request else { return }
        fail("공통 음성 권한 응답이 늦어 오디오를 중지했습니다. 다시 선택해 주세요.")
    }
    mutating func observe() -> AudioForwardingControl? {
        guard pending == nil, !failed else { return nil }
        return enqueue(try! AudioForwardingControl(requestID: UUID(), operation: .observe, intent: nil))
    }
    private mutating func enqueue(_ control: AudioForwardingControl) -> AudioForwardingControl {
        pending = Pending(control: control, connection: connection)
        return control
    }

    mutating func next(desire: Desire) -> AudioForwardingControl? {
        guard pending == nil, !failed else { return nil }
        if needsObservation || catalog == nil { return observe() }
        guard let catalog, let snapshot else { return nil }
        let own = snapshot.intent?.pairedDeviceId == device ? snapshot.intent : nil
        let action: AudioForwardingIntentRequest.Action
        let input: Bool, output: Bool, intentID: UUID, intentRevision: UInt64
        if let selected = selection {
            input = selected.microphone; output = selected.playback
            if !input && !output && own == nil { selection = nil; submitted = nil; return nil }
            action = !input && !output ? .stop : own == nil ? .request : .update
            intentID = own?.intentId ?? UUID()
            guard catalog.bootstrap.ownCursor.intentRevision.value < UInt64.max else {
                fail("음성 의도 버전을 갱신할 수 없습니다."); return nil
            }
            intentRevision = catalog.bootstrap.ownCursor.intentRevision.value + 1
        } else {
            guard !resumed, desire.microphone || desire.playback else { return nil }
            guard let own, own.inputDesired == desire.microphone, own.outputDesired == desire.playback else {
                fail("다른 기기 또는 변경된 음성 의도가 선택되어 있습니다. 이 기기에서 다시 선택해 주세요.")
                return nil
            }
            input = own.inputDesired; output = own.outputDesired
            action = .resume; intentID = own.intentId; intentRevision = own.intentRevision.value
        }
        guard catalog.bootstrap.ownCursor.bindingRevision.value < UInt64.max else {
            fail("음성 연결 버전을 갱신할 수 없습니다."); return nil
        }
        let request = try! AudioForwardingIntentRequest(pairedDeviceId: device, intentId: intentID,
            intentRevision: .init(intentRevision), action: action, inputDesired: input, outputDesired: output,
            expectedRevision: snapshot.revision, transportId: UUID(), transportKind: .native,
            bindingRevision: .init(catalog.bootstrap.ownCursor.bindingRevision.value + 1))
        selection = nil
        resumed = true
        submitted = request
        preparationReads = 0
        return enqueue(try! AudioForwardingControl(requestID: UUID(), operation: .submit, intent: request))
    }

    mutating func receive(_ state: AudioForwardingState, from generation: UUID) {
        guard generation == connection else { return }
        guard let pending, pending.connection == generation,
              pending.control.requestID == state.requestID, pending.control.operation == state.operation else {
            fail("이전 음성 권한 응답이 도착해 오디오를 중지했습니다."); return
        }
        self.pending = nil
        if state.operation == .observe, let incoming = state.catalog {
            guard incoming.role == .viewer, incoming.principal.id == device,
                  incoming.bootstrap.credential.pairedDeviceId == device,
                  catalog == nil || catalog?.principal.authorizationGeneration == incoming.principal.authorizationGeneration else {
                fail("페어링된 기기의 음성 권한 신원을 확인하지 못했습니다."); return
            }
            if let previous = catalog,
               incoming.bootstrap.ownCursor.intentRevision.value < previous.bootstrap.ownCursor.intentRevision.value ||
                incoming.bootstrap.ownCursor.bindingRevision.value < previous.bootstrap.ownCursor.bindingRevision.value {
                fail("이전 음성 연결 버전이 도착해 오디오를 중지했습니다."); return
            }
            guard accept(incoming.bootstrap.snapshot) else { return }
            catalog = incoming
            needsObservation = false
        } else if let result = state.result {
            switch result {
            case .accepted(let value):
                guard accept(value) else { return }
                needsObservation = true
            case .refused:
                fail("호스트가 음성 권한 요청을 거절했습니다. 이 기기에서 다시 선택해 주세요.")
                return
            }
        } else {
            fail("음성 권한 응답 형식을 확인하지 못했습니다."); return
        }
        if let request = submitted {
            guard let intent = snapshot?.intent, intent.pairedDeviceId == device,
                  intent.intentId == request.intentId, intent.intentRevision == request.intentRevision,
                  intent.inputDesired == request.inputDesired, intent.outputDesired == request.outputDesired else {
                fail("다른 음성 연결이 선택되어 이 기기의 오디오를 중지했습니다."); return
            }
            guard let binding = snapshot?.binding else {
                guard state.operation == .observe else { return }
                if !intent.inputDesired && !intent.outputDesired { submitted = nil; return }
                guard !recoveryUsed else {
                    fail("음성 연결이 반복해서 해제되어 오디오를 중지했습니다. 다시 선택해 주세요."); return
                }
                recoveryUsed = true
                submitted = nil
                resumed = false
                preparationReads = 0
                return
            }
            guard binding.transportKind == .native, binding.transportId == request.transportId else {
                fail("다른 음성 연결이 선택되어 이 기기의 오디오를 중지했습니다."); return
            }
            if binding.phase == .quiescing {
                preparationReads += 1
                if preparationReads >= 6 { fail("음성 연결 준비가 끝나지 않아 오디오를 중지했습니다. 다시 선택해 주세요.") }
            } else if binding.phase == .off {
                submitted = nil
            }
        }
    }
    private mutating func accept(_ value: AudioForwardingSnapshot) -> Bool {
        if let previous = snapshot {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if value.revision.value < previous.revision.value ||
                (value.revision == previous.revision && (try? encoder.encode(value.intent)) != (try? encoder.encode(previous.intent))) {
                fail("이전 음성 원장 응답이 도착해 오디오를 중지했습니다."); return false
            }
        }
        snapshot = value
        return true
    }
}

#if os(visionOS)
import Network

extension StreamClient {
    var visionForwardingDesire: VisionRemoteAudioIntent.Desire {
        .init(playback: visionPlaybackDesired, microphone: visionMicrophoneDesired)
    }

    func suspendVisionForwarding() {
        visionForwardingPoll?.cancel()
        visionForwardingPoll = nil
        visionForwarding?.suspend()
        if visionForwardingMediaBinding != nil {
            visionForwardingMediaBinding = nil
            VisionRemoteAudioStore.shared.invalidateNativeCatalog(self)
        }
    }

    func reconcileVisionForwarding(manual: Bool = false) {
        guard let peer = connection, authenticatedVisionMacAudioPeer == ObjectIdentifier(peer),
              let fingerprint = DeviceIdentity.existing()?.fingerprint,
              let device = AudioForwardingDeviceID(fingerprint: fingerprint) else { return }
        if visionForwarding?.connection != visionAudioIntentConnection {
            visionForwarding = VisionAudioForwarding(connection: visionAudioIntentConnection, device: device)
        }
        if manual { visionForwarding?.select(visionForwardingDesire) }
        guard visionAudioIntentContext.admitted else { suspendVisionForwarding(); return }
        if manual {
            VisionAudioSharedHardware.shared.revoke(owner: visionAudioOwnerID)
            visionAudio.stop()
            stopVisionMicrophoneActual()
        }
        if let control = visionForwarding?.next(desire: visionForwardingDesire) {
            sendVisionForwarding(control, to: peer)
        } else { scheduleVisionForwardingObservation(peer) }
    }

    private func scheduleVisionForwardingObservation(_ peer: NWConnection) {
        guard visionForwardingPoll == nil, visionForwarding?.pending == nil,
              visionForwarding?.shouldObserve == true else { return }
        let generation = visionAudioIntentConnection
        let work = DispatchWorkItem { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer,
                  self.visionAudioIntentConnection == generation else { return }
            self.visionForwardingPoll = nil
            guard VisionRemoteAudioStore.shared.model.owner == self.visionAudioOwnerID,
                  self.visionAudioIntentContext.admitted else { self.suspendVisionForwarding(); return }
            if let control = self.visionForwarding?.observe() { self.sendVisionForwarding(control, to: peer) }
        }
        visionForwardingPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func sendVisionForwarding(_ control: AudioForwardingControl, to peer: NWConnection) {
        visionForwardingPoll?.cancel()
        visionForwardingPoll = nil
        let generation = visionAudioIntentConnection
        let message = StreamMessage(kind: .forwardingControl, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: Wire.encode(control))
        peer.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if let error { self?.connectionLost(peer, error: error) }
        })
        if let request = control.intent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
                guard let self, let peer, self.connection === peer,
                      self.visionAudioIntentConnection == generation,
                      self.visionForwarding?.submitted?.transportId == request.transportId,
                      self.visionForwarding?.binding == nil else { return }
                self.visionForwarding?.preparationTimedOut(request.transportId)
                self.visionForwardingChanged()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer,
                  self.visionAudioIntentConnection == generation,
                  self.visionForwarding?.pending?.control.requestID == control.requestID else { return }
            self.visionForwarding?.timeout(control.requestID)
            self.visionForwardingChanged()
        }
    }

    func receiveVisionForwarding(_ header: StreamHeader, _ data: Data, from peer: NWConnection) -> Bool {
        guard header.kind == .forwardingState else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === peer,
                  self.authenticatedVisionMacAudioPeer == ObjectIdentifier(peer) else { return }
            if data.count <= 16384, let state = Wire.decode(AudioForwardingState.self, from: data) {
                self.visionForwarding?.receive(state, from: self.visionAudioIntentConnection)
            } else { self.visionForwarding?.fail("음성 권한 응답을 확인하지 못해 오디오를 중지했습니다.") }
            self.visionForwardingChanged()
        }
        return true
    }

    private func visionForwardingChanged() {
        let binding = visionForwarding?.binding
        if binding != visionForwardingMediaBinding {
            VisionAudioSharedHardware.shared.revoke(owner: visionAudioOwnerID)
            visionAudio.stop()
            stopVisionMicrophoneActual()
            visionForwardingMediaBinding = binding
            VisionRemoteAudioStore.shared.invalidateNativeCatalog(self)
        }
        visionForwardingProblem = visionForwarding?.problem
        VisionRemoteAudioStore.shared.refresh()
        if !visionPlaybackDesired && !visionMicrophoneDesired, visionForwarding?.shouldObserve == true {
            reconcileVisionForwarding()
        }
    }
}
#endif
