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
        let ticket = f.prepare(false)
        let released = await host.setRemoteProtection(false, current: { g.controlTicketIsCurrent(ticket) })
        let off = g.completeControl(ticket, result: released ? .offVerified(curtainsReleased: true,
            tapReleased: true, heldInputCleared: true) : .failed)
        expect(released && off?.operationState == .applied && !g.isRequested,
            "명시 remote OFF는 release와 persist 뒤 현재 ticket으로만 적용")
        expect(effects.suffix(4) == ["remote-release", "releasing", "release", "inactive"],
            "remote OFF 실제 표면 해제와 저널 순서 유지")
        let inactive = g.inactiveSnapshot()
        expect(inactive != nil, "인가 owner의 정당한 OFF 증명 보존")
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

        let restored = SentryAdmission()
        restored.configure(latched: true, persistenceHealthy: true)
        restored.register(peer, externalRoute: true); restored.admit(peer)
        expect(restored.isRequested && !restored.allowsActions(peer), "startup journal 기존 ON은 검증 전 차단하며 보존")
        print("MANUAL_SENTRY_CHECKS_COMPLETE \(count) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}
