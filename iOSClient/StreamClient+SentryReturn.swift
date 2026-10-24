#if os(iOS)
import Foundation
import Network
import StreamProtocol

extension StreamClient {
    var hasIPadSentryReturnKey: Bool {
        guard let binding = sentryReturn.context?.binding else { return false }
        return sentryReturnKeys.approved(binding: binding) != nil
    }
    func canManageIPadSentryReturnKey(_ action: SentryReturnKeyEnrollment.Action) -> Bool {
        sentryReturn.canRequest && sentryReturn.context?.capability.macLocal == true && sentryReturnKeyOperation == nil &&
            (action == .enroll ? !hasIPadSentryReturnKey : hasIPadSentryReturnKey)
    }
    func invalidateIPadSentryReturn() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelIPadSentryReturnWork()
        sentryReturn.invalidate()
    }
    func sentryReturnTrustChanged() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let expected = sentryReturn.context?.binding else { return }
        guard let peer = connection, sentryBinding(on: peer) == expected else {
            invalidateIPadSentryReturn(); sentryReturn.trustLost(); return
        }
    }
    private func cancelIPadSentryReturnWork() {
        sentryReturnDeviceIntent = nil
        sentryReturnKeyOperation?.cancel(); sentryReturnKeyOperation = nil
        sentryReturnKeys.invalidateSignatures()
        for submission in sentryReturnSubmissions.values { link.cancel(submission) }
        sentryReturnSubmissions.removeAll()
    }
    func observeIPadSentryReturn(catalog: Data, from peer: NWConnection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connection === peer else { return }
        let before = sentryReturn.context
        sentryReturn.observe(catalog: catalog,
            binding: sentryBinding(on: peer), from: ObjectIdentifier(peer))
        if before != sentryReturn.context { cancelIPadSentryReturnWork() }
    }
    func requestIPadSentryReturn(mode: SentryReturnAuthMode) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard appInForeground, let peer = connection, let binding = sentryBinding(on: peer),
              mode != .deviceBoundKey || sentryReturnKeys.approved(binding: binding) != nil else { return }
        cancelIPadSentryReturnWork()
        if let outbound = sentryReturn.request(mode: mode, binding: binding, from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) {
            if mode == .deviceBoundKey, let reference = sentryReturn.latest?.request.reference {
                sentryReturnDeviceIntent = (reference, ObjectIdentifier(peer))
            }
            sendIPadSentryReturn(outbound, to: peer)
        }
    }
    func queryIPadSentryReturn() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard appInForeground, let peer = connection else { return }
        cancelIPadSentryReturnWork()
        if let outbound = sentryReturn.query(binding: sentryBinding(on: peer), from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) {
            sendIPadSentryReturn(outbound, to: peer)
        }
    }
    func cancelIPadSentryReturn() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelIPadSentryReturnWork()
        guard let peer = connection else { sentryReturn.invalidate(); return }
        if let outbound = sentryReturn.cancel(binding: sentryBinding(on: peer), from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime), appInForeground {
            sendIPadSentryReturn(outbound, to: peer)
        }
    }
    func proveIPadSentryReturn() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard appInForeground, let peer = connection, let binding = sentryBinding(on: peer),
              let key = sentryReturnKeys.approved(binding: binding), let owner = key.owner else { return }
        cancelIPadSentryReturnWork()
        guard let proof = sentryReturn.beginProof(approvedOwner: owner, keyID: key.keyID, binding: binding,
            from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) else { return }
        let operation = IPadSentryReturnKeys.Operation(); sentryReturnKeyOperation = operation
        let keys = sentryReturnKeys
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak peer] in
            let result = Result { try keys.sign(proof, operation: operation) }
            DispatchQueue.main.async {
                guard let self, let peer, self.connection === peer, self.appInForeground,
                      self.sentryReturnKeyOperation === operation, self.sentryBinding(on: peer) == binding else { return }
                self.sentryReturnKeyOperation = nil
                switch result {
                case .success(let (signature, der)):
                    if let outbound = self.sentryReturn.finishProof(proof, signature: signature, publicKey: der, now: ProcessInfo.processInfo.systemUptime) {
                        self.sendIPadSentryReturn(outbound, to: peer)
                    }
                case .failure: self.sentryReturnKeyProblem = "iPad 인증 서명을 완료하지 못했습니다. 자동 재시도하지 않습니다."
                }
            }
        }
    }
    func manageIPadSentryReturnKey(_ action: SentryReturnKeyEnrollment.Action) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard appInForeground, canManageIPadSentryReturnKey(action),
              let peer = connection, let binding = sentryBinding(on: peer), sentryReturnKeyOperation == nil else { return }
        cancelIPadSentryReturnWork(); sentryReturnKeyProblem = nil
        let prior = sentryReturnKeys.approved(binding: binding)
        if action == .revoke {
            guard let prior, let enrollment = try? SentryReturnKeyEnrollment(action: .revoke, keyID: prior.keyID) else { return }
            submitIPadSentryReturnEnrollment(enrollment, binding: binding, peer: peer); return
        }
        guard (prior != nil) == (action == .rotate) else { return }
        // 이전 미확인 candidate가 있으면 같은 키만 명시적으로 재사용한다.
        if let candidate = sentryReturnKeys.candidate(binding: binding), let publicKey = candidate.publicKey,
           let enrollment = try? SentryReturnKeyEnrollment(action: action, keyID: candidate.keyID,
            publicKey: publicKey.base64EncodedString(), previousKeyID: action == .rotate ? prior?.keyID : nil) {
            submitIPadSentryReturnEnrollment(enrollment, binding: binding, peer: peer); return
        }
        let keys = sentryReturnKeys
        let operation = IPadSentryReturnKeys.Operation(); sentryReturnKeyOperation = operation
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak peer] in
            let result = Result { try keys.prepare(binding: binding, rotating: action == .rotate, operation: operation) }
            DispatchQueue.main.async {
                guard let self, let peer, self.connection === peer, self.appInForeground,
                      self.sentryReturnKeyOperation === operation, self.sentryBinding(on: peer) == binding else { return }
                self.sentryReturnKeyOperation = nil
                switch result {
                case .success(let candidate):
                    guard let publicKey = candidate.publicKey,
                          let enrollment = try? SentryReturnKeyEnrollment(action: action, keyID: candidate.keyID,
                            publicKey: publicKey.base64EncodedString(), previousKeyID: action == .rotate ? prior?.keyID : nil) else { return }
                    self.submitIPadSentryReturnEnrollment(enrollment, binding: binding, peer: peer)
                case .failure: self.sentryReturnKeyProblem = "전용 키 준비를 확인하지 못했습니다. 기존 키와 준비 기록을 보존합니다. 시뮬레이터에서는 지원하지 않습니다."
                }
            }
        }
    }
    private func submitIPadSentryReturnEnrollment(_ enrollment: SentryReturnKeyEnrollment, binding: IPadSentryReturn.Binding, peer: NWConnection) {
        if let outbound = sentryReturn.request(mode: .macLocal, enrollment: enrollment, binding: binding,
            from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime) {
            sendIPadSentryReturn(outbound, to: peer)
        }
    }
    private func sendIPadSentryReturn(_ outbound: IPadSentryReturn.Outbound, to peer: NWConnection) {
        guard appInForeground, connection === peer, sentryBinding(on: peer) == sentryReturn.context?.binding,
              outbound.bytes.first == 223, outbound.bytes.count <= StreamMessage.headerLength + 4096,
              outbound.admission.permits() else { return }
        let ticket = outbound.admission
        let id = UUID()
        let submission = SessionLink.Submission { [weak self] outcome in
            self?.sentryReturnSubmissions.removeValue(forKey: id)
            if outcome == .cancelled, ticket.permits() { self?.invalidateIPadSentryReturn() }
        }
        sentryReturnSubmissions[id] = submission
        // admit는 main 소유 모델을 읽지 않는다. 취소는 Submission을 먼저 무효화한다.
        _ = link.send(outbound.bytes, onlyOn: peer, submission: submission, admit: { ticket.permits() })
    }
    func receiveIPadSentryReturn(_ data: Data, from peer: NWConnection) {
        DispatchQueue.main.async { [weak self, weak peer] in
            guard let self, let peer, self.connection === peer, self.appInForeground,
                  self.sentryReturn.receive(data, binding: self.sentryBinding(on: peer), from: ObjectIdentifier(peer), now: ProcessInfo.processInfo.systemUptime),
                  let entry = self.sentryReturn.latest else { return }
            if let intent = self.sentryReturnDeviceIntent, intent.peer == ObjectIdentifier(peer),
               intent.reference == entry.request.reference, self.sentryReturn.canProve {
                self.sentryReturnDeviceIntent = nil
                self.proveIPadSentryReturn()
            }
            guard entry.request.keyEnrollment != nil, entry.state?.operationState == .completed else { return }
            do { try self.sentryReturnKeys.acceptEnrollment(entry) }
            catch { self.sentryReturnKeyProblem = "Mac 키 승인 결과의 로컬 저장을 확인하지 못했습니다. 인증 복귀에는 사용하지 않습니다." }
        }
    }
}
#endif
