import Foundation
import StreamProtocol

@main struct Checks {
    static var count = 0
    static func expect(_ condition: Bool, _ name: String) {
        guard condition else { print("FAIL \(name)"); exit(1) }
        count += 1
        print("PASS \(name)")
    }
    final class Peer {}
    @MainActor static func main() async {
        let emptyInputReleaseBarrier: () -> Bool = { true }
        let lanObject = Peer(), externalObject = Peer(), replacement = Peer()
        let lan = ObjectIdentifier(lanObject), external = ObjectIdentifier(externalObject)
        let gate = SentryAdmission(), epoch = UUID(), nextEpoch = UUID()
        gate.configure(latched: false, persistenceHealthy: true)
        gate.register(lan, externalRoute: false)
        expect(!gate.allows(lan, epoch: epoch), "new peer cannot receive video before coordinator admission")
        gate.admit(lan)
        expect(gate.allows(lan, epoch: epoch), "unprotected LAN session retains ordinary streaming")
        let lanState = gate.status(for: lan)!
        expect(lanState.version == 1 && lanState.phase == .inactive, "separate Sentry contract advertises inactive explicitly")
        gate.register(external, externalRoute: true)
        expect(gate.allows(lan, epoch: epoch), "외부 등록만으로 기존 LAN 영상 권한을 바꾸지 않음")
        expect(!gate.isRequested, "외부 연결만으로 Sentry ON을 만들지 않음")
        gate.admit(external)
        expect(gate.allows(external, epoch: epoch) && gate.allowsActions(external), "Sentry OFF의 원격 화면·선택 허용")
        gate.requireProtection(explicit: true)
        expect(!gate.allows(external, epoch: epoch), "external first frame awaits real protection")
        expect(!gate.allowsActions(external), "pending protection rejects remote source selection and launch")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        expect(!gate.allows(external, epoch: epoch), "surfaces alone do not attest capture exclusion")
        expect(gate.allowsActions(external), "verified physical protection permits starting a safely excluded capture")
        gate.capture(epoch)
        expect(gate.allows(external, epoch: epoch), "verified surfaces and matching capture permit remote video")
        expect(gate.status(for: external)?.phase == .userSessionProtected, "claim names user session scope")
        expect(gate.status(for: external)?.limitations.isEmpty == false, "system security and power limits remain explicit")
        expect(!gate.allows(external, epoch: nextEpoch), "queued frame from another capture is refused")
        let tagged = StreamMessage(kind: .epochFrame, timestamp: 1, isKeyframe: true,
                                   payload: PresentationMedia.encode(epoch: epoch, media: Data([1, 2])))
        expect(gate.allowsWire(tagged.serialized(), for: external, currentEpoch: epoch), "wire boundary accepts current verified epoch")
        var staleFrame = tagged
        staleFrame.payload = PresentationMedia.encode(epoch: nextEpoch, media: Data([1, 2]))
        expect(!gate.allowsWire(staleFrame.serialized(), for: external, currentEpoch: epoch), "wire boundary rejects cached foreign epoch")
        let legacy = StreamMessage(kind: .frame, timestamp: 1, isKeyframe: true, payload: Data([1, 2]))
        expect(!gate.allowsWire(legacy.serialized(), for: external, currentEpoch: epoch), "unscoped direct media cannot bypass protection")
        let thumbnail = StreamMessage(kind: .thumbnail, timestamp: 1, isKeyframe: false, payload: Data([1]))
        expect(!gate.allowsWire(thumbnail.serialized(), for: external, currentEpoch: epoch),
               "unscoped thumbnail cannot borrow current capture proof while protected")
        gate.update(verified: false, persistenceHealthy: true, reason: "입력 차단 실패")
        expect(!gate.allowsActions(external), "invalidated physical protection revokes remote source actions")
        expect(!gate.allowsWire(thumbnail.serialized(), for: external, currentEpoch: epoch), "failed protection blocks thumbnail image leaks too")
        expect(!gate.allowsWire(tagged.serialized(), for: external, currentEpoch: epoch), "late encoded frame cannot escape failed protection")
        expect(gate.status(for: external)?.phase == .blocked, "failed readback never reports protected")
        gate.update(verified: true, persistenceHealthy: false, reason: nil)
        expect(!gate.allows(external, epoch: epoch), "failed journal readback closes media despite surfaces")
        gate.update(verified: true, persistenceHealthy: true, reason: nil)
        gate.remove(external)
        expect(gate.isRequested && gate.allows(lan, epoch: epoch), "disconnect preserves protection and remaining remote functionality")
        expect(!gate.allows(external, epoch: epoch), "retired connection cannot use cached media permission")
        gate.register(ObjectIdentifier(replacement), externalRoute: false)
        gate.admit(ObjectIdentifier(replacement))
        let replacementState = gate.status(for: ObjectIdentifier(replacement))!
        expect(replacementState.sessionID != lanState.sessionID, "connection replacements have independent session identities")
        let stale = SentryActivation(hostBootID: lanState.hostBootID, sessionID: lanState.sessionID, revision: lanState.revision)
        expect(!gate.accept(stale, from: lan), "old revision cannot mutate current protection")
        let current = gate.status(for: lan)!
        let crossPeer = SentryActivation(hostBootID: current.hostBootID, sessionID: current.sessionID, revision: current.revision)
        expect(!gate.accept(crossPeer, from: ObjectIdentifier(replacement)), "another connection cannot replay a session token")
        let manualGate = SentryAdmission()
        manualGate.configure(latched: false, persistenceHealthy: true)
        manualGate.register(lan, externalRoute: false); manualGate.admit(lan)
        let idle = manualGate.status(for: lan)!
        let oldBoot = SentryActivation(hostBootID: UUID(), sessionID: idle.sessionID, revision: idle.revision)
        expect(!manualGate.accept(oldBoot, from: lan), "another host boot cannot reuse current session authority")
        let activate = SentryActivation(hostBootID: idle.hostBootID, sessionID: idle.sessionID, revision: idle.revision)
        var unsupported = try! JSONSerialization.jsonObject(with: Wire.encode(activate)) as! [String: Any]
        unsupported["version"] = 2
        let future = Wire.decode(SentryActivation.self, from: try! JSONSerialization.data(withJSONObject: unsupported))!
        expect(!manualGate.accept(future, from: lan), "unknown activation version cannot change protection")
        expect(manualGate.accept(activate, from: lan), "manual activation accepts current same-session CAS")
        expect(manualGate.isRequested && !manualGate.allows(lan, epoch: epoch), "manual acceptance fences frames before native operations")
        expect(manualGate.accept(activate, from: lan), "same request ID is idempotent across state revision")
        manualGate.capture(epoch)
        expect(manualGate.accept(activate, from: lan), "duplicate remains same effect after capture change")
        manualGate.fenceForLocalReturn()
        expect(!manualGate.allowsActions(lan), "local return fences remote source actions before any suspension")
        expect(!manualGate.accept(activate, from: lan), "local return fence refuses even old accepted activation")
        expect(!manualGate.allows(lan, epoch: epoch), "local return fence stops queued video")
        manualGate.completeLocalReturn()
        expect(manualGate.allows(lan, epoch: epoch), "인증 복귀 뒤 기존 원격 영상 연결을 유지")
        expect(!manualGate.isRequested && manualGate.status(for: lan) != nil, "인증 복귀는 화면 연결을 지우지 않고 보호 선택만 해제")
        expect(!manualGate.accept(activate, from: lan), "복귀 전 세션의 명시 활성화는 새 세대에서 거절")
        manualGate.register(external, externalRoute: true); manualGate.admit(external)
        expect(!manualGate.isRequested && manualGate.allows(external, epoch: epoch), "로컬 복귀 뒤 새 외부 연결도 OFF 유지")
        let restart = SentryAdmission()
        restart.configure(latched: true, persistenceHealthy: true)
        restart.register(lan, externalRoute: false); restart.admit(lan)
        expect(restart.isRequested && !restart.allows(lan, epoch: epoch), "persisted latch blocks LAN after process restart")
        expect(restart.status(for: lan)!.hostBootID != gate.status(for: lan)!.hostBootID, "host restart cannot reuse old capability authority")
        expect(Wire.decode(SentryActivation.self, from: Data("{}".utf8)) == nil, "missing identity and CAS are refused at decode")
        expect(StreamMessage.clientPayloadLimit(for: .activateSentry) == 512 && StreamMessage.hostPayloadLimit(for: .activateSentry) == -1,
               "activation is bounded and directional")
        expect(StreamMessage.clientPayloadLimit(for: .sentryState) == -1, "clients cannot forge host Sentry state messages")
        var durableJournal = SentryJournalState.latched
        let failedRelease = HostSentry(admission: SentryAdmission(), initiallyLatched: true, persistenceHealthy: true,
            persist: { value in
                guard value != .latched else { return false }
                durableJournal = value
                return true
            }, surfaces: .init(engage: { true }, verify: { true }, release: { _, _ in false }, reason: { nil }), prepareRelease: emptyInputReleaseBarrier, localReturnUnavailableReason: { nil })
        expect(!(await failedRelease.completeAuthenticatedLocalReturn()) && SentryJournalState.requiresProtection(durableJournal.rawValue),
               "failed native release cannot erase durable protection when relatching storage is unavailable")
        expect(durableJournal == .releasing, "durable in-progress return survives failed release and failed rollback write")
        expect(SentryJournalState.requiresProtection("corrupt") && !SentryJournalState.isValid("corrupt"),
               "unknown persisted state restarts latched and unhealthy")
        expect(SentryJournalState.requiresProtection(true) && !SentryJournalState.requiresProtection(false),
               "legacy durable boolean retains its exact protection intent")
        expect(!SentryJournalState.requiresProtection(SentryJournalState.inactive.rawValue),
               "only a committed inactive state clears the new journal")
        var effects: [String] = [], stored: Bool = false, persistOK = true, surfaceOK = true, releaseOK = true
        let controllerGate = SentryAdmission()
        let controller = HostSentry(admission: controllerGate, initiallyLatched: false, persistenceHealthy: true,
            persist: { value in effects.append(value.rawValue); if persistOK { stored = value != .inactive }; return persistOK },
            surfaces: .init(engage: { effects.append("engage"); return surfaceOK },
                            verify: { effects.append("verify"); return surfaceOK },
                            release: { _, _ in effects.append("release"); return releaseOK }, reason: { "가림막 확인 실패" }), prepareRelease: emptyInputReleaseBarrier, localReturnUnavailableReason: { nil })
        controllerGate.register(lan, externalRoute: false)
        controller.joined(lan)
        expect(effects.isEmpty && controllerGate.allows(lan, epoch: epoch), "ordinary LAN join makes no native protection effects")
        expect(controller.activate() && stored, "manual activation durably latches and verifies native surfaces")
        expect(effects == ["latched", "engage", "verify"], "journal commits before native protection readback")
        controllerGate.capture(epoch)
        expect(controllerGate.allows(lan, epoch: epoch), "native verified activation permits matching capture")
        surfaceOK = false
        controller.surfacesChanged()
        expect(stored && !controllerGate.allows(lan, epoch: epoch), "lost native protection closes gate while retaining journal")
        surfaceOK = true; persistOK = false
        expect(!controller.reconcile() && !controllerGate.allows(lan, epoch: epoch), "persistence failure cannot be hidden by successful surfaces")
        let releasesBefore = effects.filter { $0 == "release" }.count
        expect(!(await controller.completeAuthenticatedLocalReturn()) && stored, "failed clear keeps protection latched")
        expect(effects.filter { $0 == "release" }.count == releasesBefore, "failed clear never releases curtain or input filter")
        persistOK = true; releaseOK = false
        expect(!(await controller.completeAuthenticatedLocalReturn()) && stored, "failed surface release reasserts durable latch")
        releaseOK = true
        let beforeNativeReturn = controllerGate.status(for: lan)!
        expect(await controller.completeAuthenticatedLocalReturn() && !stored, "successful authenticated return clears native and persisted protection")
        expect(controllerGate.status(for: lan)?.sessionID != beforeNativeReturn.sessionID && controllerGate.allowsActions(lan),
               "인증된 복귀 뒤 기존 화면 연결은 새 세대로 유지")
        let staleNativeActivation = SentryActivation(hostBootID: beforeNativeReturn.hostBootID,
            sessionID: beforeNativeReturn.sessionID, revision: beforeNativeReturn.revision)
        expect(!controllerGate.accept(staleNativeActivation, from: lan), "복귀 전 원격 권한은 새 영상 연결에서 재사용 불가")
        expect(!controllerGate.allowsWire(Data([0, 1]), for: lan, currentEpoch: epoch), "malformed queued wire cannot bypass gate")
        let callbackGate = SentryAdmission()
        var callback: (() -> Void)?
        var callbackEffects: [String] = []
        let callbackController = HostSentry(admission: callbackGate, initiallyLatched: true, persistenceHealthy: true,
            persist: { callbackEffects.append($0.rawValue); return true },
            surfaces: .init(engage: { callbackEffects.append("engage"); callback?(); return true },
                            verify: { true },
                            release: { _, _ in callbackEffects.append("release"); callback?(); return true }, reason: { nil }), prepareRelease: emptyInputReleaseBarrier, localReturnUnavailableReason: { nil })
        callback = { [weak callbackController] in callbackController?.surfacesChanged() }
        callbackController.start()
        callbackEffects.removeAll()
        expect(await callbackController.completeAuthenticatedLocalReturn(), "native release callbacks allow authenticated local return")
        expect(callbackEffects == ["releasing", "release", "inactive"], "release callback cannot reengage native protection or relatch storage")
        expect(!callbackGate.isRequested, "release callbacks leave the completed return inactive")
        let independent = SentryAdmission()
        independent.configure(latched: true, persistenceHealthy: true)
        independent.register(lan, externalRoute: false)
        independent.register(external, externalRoute: false)
        independent.admit(lan); independent.admit(external)
        independent.update(verified: true, persistenceHealthy: true, reason: nil)
        independent.capture(epoch)
        independent.capture(nil, for: lan)
        independent.capture(nextEpoch, for: external)
        expect(!independent.allows(lan, epoch: epoch), "unready independent peer cannot borrow legacy capture proof")
        expect(independent.allows(external, epoch: nextEpoch), "independent second peer retains its own capture proof")
        expect(!independent.allows(external, epoch: epoch), "independent peers cannot borrow another epoch")
        expect(independent.status(for: lan)?.phase == .pending, "uncaptured peer reports pending even while another is protected")
        expect(independent.status(for: external)?.phase == .userSessionProtected, "captured peer reports its own protected state")
        independent.capture(epoch, for: lan)
        expect(independent.allows(lan, epoch: epoch) && independent.allows(external, epoch: nextEpoch), "two different monitor epochs stream concurrently")
        independent.remove(lan)
        expect(independent.isRequested && independent.allows(external, epoch: nextEpoch), "one disconnect keeps latch and other peer video")
        independent.register(lan, externalRoute: false); independent.admit(lan)
        independent.capture(nil, for: lan)
        expect(!independent.allows(lan, epoch: epoch), "reconnected peer cannot reuse old independent capture")
        let stableGate = SentryAdmission()
        let stable = HostSentry(admission: stableGate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { true }, verify: { true },
                release: { _, _ in true }, reason: { nil }), prepareRelease: emptyInputReleaseBarrier, localReturnUnavailableReason: { nil })
        stable.start()
        let surfaceProof = stable.forwardingProof()!
        stableGate.register(lan, externalRoute: false); stable.joined(lan)
        stable.membershipWillChange()
        stableGate.capture(epoch, for: lan)
        stable.surfacesChanged()
        expect(stable.forwardingProofCurrent(surfaceProof), "healthy periodic readback and viewer membership retain physical proof")
        stableGate.capture(nextEpoch, for: lan)
        expect(stable.forwardingProofCurrent(surfaceProof), "switching one remote monitor does not revoke unrelated audio protection")
        stableGate.update(verified: false, persistenceHealthy: true, reason: "실제 보호 상실")
        expect(!stable.forwardingProofCurrent(surfaceProof), "real protection loss invalidates physical proof synchronously")
        let videoOnlyGate = SentryAdmission()
        var audioVerified = false
        var surfacesVerified = true
        let videoOnly = HostSentry(admission: videoOnlyGate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { surfacesVerified }, verify: { surfacesVerified },
                release: { _, _ in true }, reason: { nil }), prepareRelease: emptyInputReleaseBarrier, audioReady: { audioVerified }, localReturnUnavailableReason: { nil })
        videoOnlyGate.register(lan, externalRoute: false)
        videoOnly.start(); videoOnly.joined(lan)
        expect(videoOnlyGate.allowsActions(lan), "verified physical protection permits source selection despite unavailable audio")
        expect(!videoOnlyGate.allows(lan, epoch: epoch), "video still requires an independent capture exclusion epoch")
        videoOnlyGate.capture(epoch, for: lan)
        expect(videoOnlyGate.allows(lan, epoch: epoch), "audio failure does not black out an approved capture")
        expect(videoOnly.forwardingProof() == nil, "video permission cannot authorize unverified audio forwarding")
        audioVerified = true
        let audioProof = videoOnly.forwardingProof()!
        audioVerified = false
        expect(!videoOnly.forwardingProofCurrent(audioProof), "audio readback loss synchronously invalidates audio proof")
        expect(videoOnlyGate.allows(lan, epoch: epoch), "audio proof revocation preserves protected remote video")
        surfacesVerified = false
        videoOnly.surfacesChanged()
        expect(!videoOnlyGate.allowsActions(lan) && !videoOnlyGate.allows(lan, epoch: epoch), "physical protection failure still fences remote input and video")
        await remoteProtectionChecks()
        print("SENTRY_CHECKS_COMPLETE \(count)")
    }

    @MainActor static func remoteProtectionChecks() async {
        let onGate = SentryAdmission()
        let on = HostSentry(admission: onGate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { true }, verify: { true }, release: { _, _ in false },
                reason: { nil }), prepareRelease: { false }, localReturnUnavailableReason: { nil })
        let onAccepted = await on.setRemoteProtection(true, until: .now.advanced(by: .seconds(-1)), current: { true })
        expect(onAccepted, "OFF 대기용 만료 deadline은 기존 ON 복구·authority 검증에 새 시간상한을 만들지 않음")

        for failure in ["none", "debt", "releasing", "release", "readback", "inactive", "revoked"] {
            let gate = SentryAdmission()
            var effects: [String] = []
            var released = false, current = true
            let host = HostSentry(admission: gate, initiallyLatched: true, persistenceHealthy: true,
                persist: { state in
                    effects.append(state.rawValue)
                    return !(failure == "releasing" && state == .releasing) && !(failure == "inactive" && state == .inactive)
                }, surfaces: .init(engage: { false }, verify: { false }, release: { _, _ in
                    effects.append("surface")
                    released = failure != "release"
                    if failure == "revoked" { current = false }
                    return released
                }, reason: { nil }, restoreCurtains: { true }, released: { released && failure != "readback" }),
                prepareRelease: { effects.append("local-authenticated-path"); return false },
                prepareRemoteRelease: { effects.append("remote-debt"); return failure != "debt" },
                localReturnUnavailableReason: { "로컬 오디오 복귀는 별도 인증이 필요합니다." })
            gate.update(verified: false, persistenceHealthy: true, reason: "권한창이 가림 화면 위에 있습니다.")
            let result = await host.setRemoteProtection(false, current: { current })
            expect(result == (failure == "none"), "remote off requires independent physical readback and current trust: \(failure)")
            expect(!effects.contains("local-authenticated-path"), "remote off never invokes authenticated audio return: \(failure)")
            expect(gate.isRequested, "physical result alone cannot commit control authority or clear session state: \(failure)")
            if failure == "none" {
                expect(effects == ["remote-debt", "releasing", "surface", "inactive"],
                       "remote off persists around verified surface release without audio actions")
            } else if failure == "debt" {
                expect(effects == ["remote-debt"], "unsettled input cannot begin physical release")
            }
        }
        let gate = SentryAdmission()
        var effects = 0
        let host = HostSentry(admission: gate, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in effects += 1; return true }, surfaces: .init(engage: { true }, verify: { true },
                release: { _, _ in effects += 1; return true }, reason: { nil }), prepareRelease: { true },
            localReturnUnavailableReason: { nil })
        expect(!(await host.setRemoteProtection(false, current: { false })) && effects == 0,
               "revoked remote authority cannot touch journal or native surfaces")
    }
}
