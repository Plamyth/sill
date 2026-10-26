import Foundation
import StreamProtocol

@main struct Checks {
    static var count = 0
    static var failures = 0
    static func expect(_ value: Bool, _ name: String) {
        count += 1
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL") \(name)")
    }
    @MainActor final class ReleaseGate {
        var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
    final class Fixture {
        let gate = SentryAdmission(), object = NSObject()
        let device = String(repeating: "ab", count: 32)
        var peer: ObjectIdentifier { ObjectIdentifier(object) }
        init() {
            gate.configure(latched: false, persistenceHealthy: true)
            gate.register(peer, externalRoute: false); gate.admit(peer)
            grant()
        }
        func grant() {
            _ = gate.grantControl(to: peer, verifiedOwner: .init(deviceID: device,
                encryptedTLS: true, currentPairedOwner: true)!)
        }
        func prepare(_ desired: Bool) -> SentryAdmission.ControlTicket {
            let state = gate.status(for: peer)!
            let request = try! SentryControlRequest(hostBootID: state.hostBootID, sessionID: state.sessionID,
                revision: state.revision, authorizationGeneration: state.control!.authorizationGeneration, desired: desired)
            guard case .prepared(let ticket, _) = gate.prepareControl(request, from: peer) else {
                fatalError("현재 인가로 전환 준비 실패")
            }
            return ticket
        }
        @discardableResult func off() -> SentryAdmission.ControlTicket {
            let ticket = prepare(false)
            let result = gate.completeControl(ticket, result: .offVerified(curtainsReleased: true,
                tapReleased: true, heldInputCleared: true))
            expect(result?.operationState == .applied && !gate.isRequested, "정당한 OFF 실제 종료 증명 적용")
            return ticket
        }
        func legacy() -> SentryActivation {
            let state = gate.status(for: peer)!
            return SentryActivation(hostBootID: state.hostBootID, sessionID: state.sessionID, revision: state.revision)
        }
    }
    @MainActor static func main() async {
        // OS 경계는 주입된 함수뿐이며 production Admission/HostSentry를 직접 호출한다.
        let f = Fixture(), g = f.gate
        var effects: [String] = []
        let host = HostSentry(admission: g, initiallyLatched: false, persistenceHealthy: true,
            persist: { effects.append($0.rawValue); return true },
            surfaces: .init(engage: { effects.append("engage"); return true },
                verify: { effects.append("verify"); return true }, release: { _, current in
                    effects.append("release"); return current()
                }, reason: { nil }, released: { true }),
            prepareRelease: { effects.append("local-release"); return true },
            prepareRemoteRelease: { effects.append("remote-release"); return true },
            localReturnUnavailableReason: { nil })
        let other = NSObject(), peer = ObjectIdentifier(other)
        g.register(peer, externalRoute: true); host.joined(peer)
        host.start(recoverAudio: { effects.append("audio-arm") })
        g.requireProtection() // 기존 연결 콜백이며 명시 조작이 아니다.
        host.surfacesChanged()
        expect(!g.isRequested && g.allowsActions(peer), "화면·확장 단순 연결과 자동 요청은 Sentry OFF 유지")
        expect(effects.isEmpty, "화면만 연결하면 표면·저널·오디오 arm 호출 모두 0")

        let originalOn = f.legacy()
        expect(g.accept(originalOn, from: f.peer), "현재 legacy 명시 ON 허용")
        expect(host.activate(), "명시 ON은 실제 표면 readback 수행")
        host.start(recoverAudio: { effects.append("audio-arm") })
        expect(!effects.contains("audio-arm"), "명시 Sentry ON과 후속 시작은 오디오 arm·복구를 호출하지 않음")
        let ticket = f.prepare(false)
        let effectsBeforeBusy = effects
        expect(!host.activate() && g.controlTicketIsCurrent(ticket) && effects == effectsBeforeBusy,
            "진행 중인 현재 OFF ticket을 로컬 activate가 덮지 않음")
        let released = await host.setRemoteProtection(false, current: { g.controlTicketIsCurrent(ticket) })
        let off = g.completeControl(ticket, result: released ? .offVerified(curtainsReleased: true,
            tapReleased: true, heldInputCleared: true) : .failed)
        expect(released && off?.operationState == .applied && !g.isRequested,
            "명시 remote OFF는 release와 persist 뒤 현재 ticket으로만 적용")
        expect(effects.suffix(4) == ["remote-release", "releasing", "release", "inactive"],
            "remote OFF 실제 표면 해제와 저널 순서 유지")
        let inactive = g.inactiveSnapshot()
        expect(inactive != nil, "인가 owner의 정당한 OFF 증명 보존")
        let beforeUnauthorised = g.status(for: f.peer)
        let unauthorizedOn = await host.setRemoteProtection(true, current: { false })
        let unauthorizedOff = await host.setRemoteProtection(false, current: { false })
        expect(!unauthorizedOn && !unauthorizedOff && beforeUnauthorised == g.status(for: f.peer),
            "현재 인가 없는 ON·OFF는 admission과 표면을 변경하지 않음")
        expect(!g.accept(originalOn, from: f.peer) && !g.isRequested,
            "OFF 이전 legacy ON 재전송은 새 ON 선택으로 재활성화하지 않음")
        g.requireProtection()
        g.remove(peer); g.register(peer, externalRoute: true); host.joined(peer)
        expect(!g.isRequested && inactive.map(g.inactiveMatches) == true,
            "OFF 뒤 disconnect·register·admit·자동 요청이 선택과 증명을 보존")
        expect(host.activate() && g.isRequested && g.status(for: f.peer)?.control?.manualIntent == .on,
            "OFF 이후 새로운 로컬 명시 activate는 정당한 ON 선택")

        let cancelled = Fixture()
        cancelled.off()
        let pending = cancelled.prepare(false)
        cancelled.gate.remove(cancelled.peer)
        cancelled.gate.register(cancelled.peer, externalRoute: true); cancelled.gate.admit(cancelled.peer)
        cancelled.grant()
        let beforeLate = cancelled.gate.status(for: cancelled.peer)
        _ = cancelled.gate.completeControl(pending, result: .onPrepared(surfacesVerified: true))
        expect(!cancelled.gate.isRequested && beforeLate == cancelled.gate.status(for: cancelled.peer),
            "새 OFF 뒤 pending OFF 취소·재접속·늦은 callback은 ON을 만들지 않음")
        expect(!cancelled.gate.controlTicketIsCurrent(pending), "이전 session ticket은 현재성 상실")

        let failed = Fixture()
        failed.off()
        let failing = failed.prepare(false)
        let failedReply = failed.gate.completeControl(failing, result: .failed)
        expect(failedReply?.code == .controlFailed && !failed.gate.isRequested,
            "이미 OFF에서 실패한 OFF 재요청도 ON을 만들지 않음")
        let revoked = Fixture()
        revoked.off()
        revoked.gate.register(peer, externalRoute: true); revoked.gate.admit(peer)
        revoked.gate.revokeControl(forDeviceID: revoked.device)
        expect(!revoked.gate.isRequested && revoked.gate.inactiveSnapshot() == nil,
            "owner 권한 회수는 OFF 유지하되 inactive 인가 증명을 회수")
        revoked.gate.remove(peer); revoked.gate.register(peer, externalRoute: true); revoked.gate.admit(peer)
        expect(!revoked.gate.isRequested, "권한 회수 뒤 재접속도 ON 선택을 생성하지 않음")

        let cold = Fixture()
        expect(cold.gate.inactiveSnapshot() == nil, "단순 inactive는 인증 OFF 증명으로 승격하지 않음")
        var restoreEffects: [String] = []
        let coldHost = HostSentry(admission: cold.gate, initiallyLatched: false, persistenceHealthy: true,
            persist: { restoreEffects.append($0.rawValue); return true },
            surfaces: .init(engage: { restoreEffects.append("engage"); return true }, verify: { true },
                release: { _, _ in false }, reason: { nil }, released: { false }),
            prepareRelease: { true }, localReturnUnavailableReason: { nil })
        let coldOff = cold.prepare(false)
        let coldResult = await coldHost.setRemoteProtection(false, current: { cold.gate.controlTicketIsCurrent(coldOff) })
        _ = cold.gate.completeControl(coldOff, result: coldResult ? .offVerified(curtainsReleased: true,
            tapReleased: true, heldInputCleared: true) : .failed)
        expect(!coldResult && !cold.gate.isRequested && !restoreEffects.contains("engage") && !restoreEffects.contains("latched"),
            "기존 ON이 없는 해제 실패는 보호 engage·latched를 새로 만들지 않음")
        expect(!restoreEffects.contains("releasing"), "기존 ON 없는 실패가 startup ON 복원용 releasing 저널도 만들지 않음")

        let late = Fixture(), releaseGate = ReleaseGate()
        var lateEffects: [String] = []
        let lateHost = HostSentry(admission: late.gate, initiallyLatched: true, persistenceHealthy: true,
            persist: { lateEffects.append($0.rawValue); return true },
            surfaces: .init(engage: { lateEffects.append("engage"); return true }, verify: { true },
                release: { _, current in await releaseGate.wait(); return current() },
                reason: { nil }, released: { true }), prepareRelease: { true },
            localReturnUnavailableReason: { nil })
        let oldTicket = late.prepare(false)
        let oldRelease = Task { await lateHost.setRemoteProtection(false, current: { late.gate.controlTicketIsCurrent(oldTicket) }) }
        while !releaseGate.entered { await Task.yield() }
        late.gate.remove(late.peer)
        late.gate.register(late.peer, externalRoute: true); late.gate.admit(late.peer); late.grant()
        late.off()
        let newestOff = late.gate.status(for: late.peer), effectsAfterOff = lateEffects
        releaseGate.resume()
        let lateResult = await oldRelease.value
        _ = late.gate.completeControl(oldTicket, result: lateResult ? .offVerified(curtainsReleased: true,
            tapReleased: true, heldInputCleared: true) : .failed)
        expect(!lateResult && !late.gate.isRequested && late.gate.status(for: late.peer) == newestOff && lateEffects == effectsAfterOff,
            "새 session의 OFF 뒤 이전 해제 callback은 정책·표면·저널을 덮지 않음")

        let restored = SentryAdmission()
        restored.configure(latched: true, persistenceHealthy: true)
        restored.register(peer, externalRoute: true); restored.admit(peer)
        expect(restored.isRequested && !restored.allowsActions(peer), "startup journal 기존 ON은 검증 전 차단하며 보존")
        var audioEffects = 0, preservedLocal = 0
        let restoredHost = HostSentry(admission: restored, initiallyLatched: true, persistenceHealthy: true,
            persist: { _ in true }, surfaces: .init(engage: { true }, verify: { true },
                release: { _, current in current() }, reason: { nil }, released: { true }),
            prepareRelease: { true }, audioReady: { audioEffects += 1; return false },
            localReturnUnavailableReason: { nil })
        restoredHost.start(recoverAudio: { audioEffects += 1 })
        expect(restored.isRequested && audioEffects == 0,
            "정당한 startup Sentry ON 복원도 오디오 arm·proof를 요구하지 않음")
        let returned = await restoredHost.completeAuthenticatedLocalReturn(commitAudio: { preservedLocal += 1; return true })
        expect(returned && !restored.isRequested && preservedLocal == 1 && audioEffects == 0,
            "never-armed 인증 복귀는 기존 preserveLocal 커밋을 사용하며 origin·HAL 효과를 새로 만들지 않음")
        await localReturnContinuityChecks()
        print("MANUAL_SENTRY_CHECKS_COMPLETE \(count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }

    @MainActor static func localReturnContinuityChecks() async {
        let f = Fixture(), gate = f.gate, release = ReleaseGate()
        let secondObject = NSObject(), unadmittedObject = NSObject(), ungrantedObject = NSObject()
        let second = ObjectIdentifier(secondObject), unadmitted = ObjectIdentifier(unadmittedObject)
        let ungranted = ObjectIdentifier(ungrantedObject), secondDevice = String(repeating: "cd", count: 32)
        gate.register(second, externalRoute: true); gate.admit(second)
        _ = gate.grantControl(to: second, verifiedOwner: .init(deviceID: secondDevice,
            encryptedTLS: true, currentPairedOwner: true)!)
        gate.register(unadmitted, externalRoute: true)
        gate.register(ungranted, externalRoute: true); gate.admit(ungranted)
        let sharedEpoch = UUID(), independentEpoch = UUID()
        gate.capture(sharedEpoch); gate.capture(independentEpoch, for: second)

        func request(_ state: SentryState, desired: Bool, authorization: UUID? = nil,
                     session: UUID? = nil, revision: UUID? = nil) -> SentryControlRequest {
            try! SentryControlRequest(hostBootID: state.hostBootID, sessionID: session ?? state.sessionID,
                revision: revision ?? state.revision,
                authorizationGeneration: authorization ?? state.control!.authorizationGeneration, desired: desired)
        }
        func rejected(_ request: SentryControlRequest, from peer: ObjectIdentifier) -> Bool {
            switch gate.prepareControl(request, from: peer) {
            case .rejected(let response): return !response.accepted
            case .unauthorized: return true
            case .prepared, .readback: return false
            }
        }

        var effects: [String] = []
        let host = HostSentry(admission: gate, initiallyLatched: false, persistenceHealthy: true,
            persist: { effects.append($0.rawValue); return true },
            surfaces: .init(engage: { effects.append("engage"); return true }, verify: { true },
                release: { _, current in effects.append("release"); await release.wait(); return current() },
                reason: { nil }, released: { true }),
            prepareRelease: { effects.append("prepare"); return true },
            localReturnUnavailableReason: { nil })
        let legacy = f.legacy()
        expect(gate.accept(legacy, from: f.peer) && host.activate(), "복귀 회귀 사전조건: 기존 명시 ON 적용")
        let appliedRequest = request(gate.status(for: f.peer)!, desired: true)
        if case .prepared(let ticket, _) = gate.prepareControl(appliedRequest, from: f.peer) {
            expect(gate.completeControl(ticket, result: .onVerified(surfacesVerified: true,
                captureEpoch: sharedEpoch))?.operationState == .applied, "복귀 전 완료 operation 원장 생성")
        } else { expect(false, "복귀 전 완료 operation 준비") }
        expect(gate.allows(f.peer, epoch: sharedEpoch) && gate.allows(second, epoch: independentEpoch),
            "복귀 전 기존 두 연결의 공유·독립 영상 허용")
        let before = gate.status(for: f.peer)!, secondBefore = gate.status(for: second)!
        let readyBefore = gate.sourceSelectionAdmission(for: f.peer)!
        let secondReadyBefore = gate.sourceSelectionAdmission(for: second)!
        let oldPending = f.prepare(false)
        host.localReturnActivityChanged(true)
        let returning = Task { await host.completeAuthenticatedLocalReturn(until: .now.advanced(by: .seconds(30)),
            commitAudio: { effects.append("audio-origin-restored"); return true }) }
        while !release.entered { await Task.yield() }
        expect(!gate.allowsActions(f.peer) && !gate.allowsActions(second) &&
            !gate.allows(f.peer, epoch: sharedEpoch) && !gate.allows(second, epoch: independentEpoch),
            "인증 복귀 진행 중 두 연결의 명령·영상은 fenced")
        expect(gate.sourceSelectionAdmission(for: f.peer)?.ready == false &&
            gate.sourceSelectionAdmission(for: second)?.ready == false &&
            gate.status(for: f.peer)?.phase == .blocked, "인증 복귀 진행 중 ready와 상태도 차단")
        expect(!gate.controlTicketIsCurrent(oldPending) && !gate.accept(legacy, from: f.peer) &&
            rejected(request(gate.status(for: second)!, desired: true), from: second) && !host.activate(),
            "복귀 fence는 구 operation·activation과 새 명시 요청도 완료 전 차단")
        expect(!effects.contains("audio-origin-restored"), "표면 해제 대기 중 오디오 원본 복원 커밋을 앞당기지 않음")
        release.resume()
        let returned = await returning.value
        expect(returned && effects.suffix(3) == ["release", "audio-origin-restored", "inactive"],
            "인증 복귀는 표면 해제→오디오 원본 복원→inactive 저장 순서 유지")
        expect(!gate.allowsActions(f.peer) && !gate.allowsActions(second),
            "복귀 커밋 뒤에도 인증 요청 종료 통지 전까지 fence 유지")
        host.localReturnActivityChanged(false)

        // 세션이 삭제되는 구 구현에서도 fatalError 없이 모든 실패를 수집한다.
        let after = gate.status(for: f.peer), secondAfter = gate.status(for: second)
        expect(after != nil && secondAfter != nil, "복귀 뒤 기존 두 연결의 status 생존")
        expect(after.map { $0.hostBootID == before.hostBootID && $0.sessionID == before.sessionID &&
            $0.revision != before.revision } == true && secondAfter.map { $0.sessionID == secondBefore.sessionID } == true,
            "같은 두 연결의 sessionID는 유지하고 구 revision만 무효화")
        expect(after?.control != nil && secondAfter?.control != nil &&
            after?.control?.authorizationGeneration != before.control?.authorizationGeneration &&
            secondAfter?.control?.authorizationGeneration != secondBefore.control?.authorizationGeneration,
            "기존 두 owner만 control capability 유지하며 각 authorization 회전")
        expect(after?.phase == .inactive && secondAfter?.phase == .inactive && !gate.isRequested &&
            after?.control?.manualIntent == .off && secondAfter?.control?.manualIntent == .off,
            "인증 복귀 뒤 명시 센츄리 선택은 OFF이며 일반 모드")
        expect(gate.allowsActions(f.peer) && gate.allowsActions(second) &&
            gate.allows(f.peer, epoch: sharedEpoch) && gate.allows(second, epoch: independentEpoch),
            "재등록·재인가 없이 기존 두 연결의 명령·영상 허용 복원")
        expect(gate.sourceSelectionAdmission(for: f.peer).map { $0.ready && $0.generation > readyBefore.generation } == true &&
            gate.sourceSelectionAdmission(for: second).map { $0.ready && $0.generation > secondReadyBefore.generation } == true,
            "기존 두 연결에 복귀 후 새 ready 세대 발급")
        expect(gate.status(for: unadmitted) != nil && !gate.allowsActions(unadmitted) &&
            !gate.allows(unadmitted, epoch: sharedEpoch) && gate.sourceSelectionAdmission(for: unadmitted)?.ready == false &&
            gate.status(for: unadmitted)?.control == nil, "기존 미인가 peer는 생존하되 admitted·control 신뢰 확대 없음")
        expect(gate.status(for: ungranted) != nil && gate.allowsActions(ungranted) &&
            gate.status(for: ungranted)?.control == nil, "기존 영상 허용 peer에도 control 권한을 새로 만들지 않음")
        let unchanged = gate.status(for: f.peer)
        expect(gate.completeControl(oldPending, result: .offVerified(curtainsReleased: true,
            tapReleased: true, heldInputCleared: true)) == nil && !gate.controlTicketIsCurrent(oldPending) &&
            gate.status(for: f.peer) == unchanged, "복귀 이전 pending operation의 늦은 완료는 폐기")
        expect(rejected(appliedRequest, from: f.peer) && rejected(oldPending.request, from: f.peer) &&
            !gate.accept(legacy, from: f.peer) && gate.status(for: f.peer) == unchanged,
            "구 완료·pending 요청과 legacy activation replay는 readback·재적용 없이 거절")
        gate.requireProtection(); host.start(); host.joined(f.peer); host.joined(second); host.surfacesChanged()
        expect(!gate.isRequested && gate.status(for: f.peer) == unchanged && !effects.contains("audio-arm"),
            "연결·시작·표면 콜백과 자동 활성화는 명시 OFF를 덮지 않음")

        if let after, let secondAfter, after.control != nil, secondAfter.control != nil {
            expect(rejected(request(after, desired: true, authorization: before.control!.authorizationGeneration), from: f.peer) &&
                rejected(request(secondAfter, desired: true, authorization: secondBefore.control!.authorizationGeneration), from: second),
                "같은 session·새 revision을 사용해도 이전 두 authorization은 거절")
            expect(rejected(request(after, desired: true, session: UUID()), from: f.peer) &&
                rejected(request(after, desired: true, revision: before.revision), from: f.peer),
                "새 authorization을 사용해도 다른 session 또는 이전 revision은 거절")
            expect(rejected(request(after, desired: true), from: unadmitted) &&
                rejected(request(after, desired: true), from: ungranted), "복귀 뒤 미인가·control 없는 peer의 명시 요청도 거절")
            expect(!gate.accept(SentryActivation(hostBootID: after.hostBootID, sessionID: UUID(),
                revision: after.revision), from: f.peer) &&
                !gate.accept(SentryActivation(hostBootID: after.hostBootID, sessionID: after.sessionID,
                revision: before.revision), from: f.peer), "legacy 경로도 다른 session·이전 revision은 각각 거절")
            if case .prepared(let fresh, _) = gate.prepareControl(request(after, desired: true), from: f.peer) {
                expect(gate.completeControl(fresh, result: .onVerified(surfacesVerified: true,
                    captureEpoch: sharedEpoch))?.operationState == .applied, "새 세대의 명시 ON만 실제 적용")
                expect(gate.allows(f.peer, epoch: sharedEpoch) && !gate.allows(f.peer, epoch: independentEpoch) &&
                    gate.allows(second, epoch: independentEpoch) && !gate.allows(second, epoch: sharedEpoch) &&
                    gate.status(for: second)?.phase == .userSessionProtected,
                    "새 ON에서도 공유 epoch와 독립 peer epoch·구분 보존 확인")
            } else { expect(false, "복귀 뒤 새 명시 ON 준비") }

            // independent nil은 공유 epoch로 대체되면 안 된다.
            gate.capture(nil, for: second)
            gate.fenceForLocalReturn(); gate.completeLocalReturn()
            if let current = gate.status(for: f.peer), current.control != nil,
               case .prepared(let fresh, _) = gate.prepareControl(request(current, desired: true), from: f.peer) {
                _ = gate.completeControl(fresh, result: .onVerified(surfacesVerified: true, captureEpoch: sharedEpoch))
                expect(gate.allows(f.peer, epoch: sharedEpoch) && !gate.allows(second, epoch: sharedEpoch) &&
                    gate.status(for: second)?.phase == .pending,
                    "재복귀도 독립 nil 캡처를 공유 영상으로 승격하지 않음")
            } else { expect(false, "재복귀 뒤 새 명시 ON 준비") }
        }
    }
}
