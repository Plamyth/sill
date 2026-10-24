import Foundation
import StreamProtocol

final class NWConnection {
    enum State { case ready, cancelled }
    var state = State.ready
}
struct ClientRoute {
    var encrypted: Bool
    var fingerprint: Data?
}
final class TrustedDevices {
    var keys: Set<Data> = []
    func isPaired(_ key: Data) -> Bool { keys.contains(key) }
}
final class ControlServer {
    let sentryAdmission = SentryAdmission()
    var messages: [StreamMessage] = []
    func send(_ message: StreamMessage, to connection: NWConnection) { messages.append(message) }
}
@MainActor final class ControlCoordinator {
    var synthetic = false, shuttingDown = false
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var routes: [ObjectIdentifier: ClientRoute] = [:]
    let server = ControlServer()
    var remote: TrustedDevices? = TrustedDevices()
    var sentry: HostSentry?
    var effects: [String] = []
    var surface = false, releaseOK = true, debt = false, audioVerified = true
    init() {
        sentry = HostSentry(admission: server.sentryAdmission, initiallyLatched: false, persistenceHealthy: true,
            persist: { [unowned self] value in effects.append(value.rawValue); return true },
            surfaces: .init(engage: { [unowned self] in surface = true; effects.append("engage"); return true },
                verify: { [unowned self] in surface }, release: { [unowned self] in
                    effects.append("release"); if releaseOK { surface = false }; return releaseOK
                }, reason: { nil }, restoreCurtains: { true }, released: { [unowned self] in !surface }),
            prepareRelease: { false }, prepareRemoteRelease: { [unowned self] in !debt },
            audioReady: { [unowned self] in audioVerified },
            localReturnUnavailableReason: { nil })
    }
    func join(_ connection: NWConnection, fingerprint: Data, encrypted: Bool = true, paired: Bool = true) {
        let peer = ObjectIdentifier(connection)
        connections[peer] = connection
        routes[peer] = .init(encrypted: encrypted, fingerprint: fingerprint)
        if paired { remote?.keys.insert(fingerprint) }
        server.sentryAdmission.register(peer, externalRoute: encrypted)
        sentry!.joined(peer)
        grantSentryControl(to: peer, route: routes[peer]!)
    }
    func leave(_ connection: NWConnection) {
        let peer = ObjectIdentifier(connection)
        connections[peer] = nil
        routes[peer] = nil
        server.sentryAdmission.remove(peer)
    }
    func receive(_ payload: Data, from connection: NWConnection) -> SentryControlResponse? {
        let count = server.messages.count
        activateSentry(.init(kind: .activateSentry, timestamp: 1, isKeyframe: false, payload: payload), from: connection)
        guard server.messages.count > count else { return nil }
        return try? SentryControlResponse.decodePayload(server.messages.last!.payload)
    }
    func request(_ desired: Bool, from connection: NWConnection, requestID: UUID = UUID()) -> SentryControlRequest {
        let state = server.sentryAdmission.status(for: ObjectIdentifier(connection))!
        return try! SentryControlRequest(requestID: requestID, hostBootID: state.hostBootID,
            sessionID: state.sessionID, revision: state.revision,
            authorizationGeneration: state.control!.authorizationGeneration, desired: desired)
    }
    __PRODUCTION_CONTROL__
}

@main struct ControlChecks {
    static var count = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL \(message)"); exit(1) }
        count += 1; print("PASS \(message)")
    }
    @MainActor static func main() {
        let key = Data(repeating: 3, count: 32), connection = NWConnection(), coordinator = ControlCoordinator()
        coordinator.join(connection, fingerprint: key)
        let state = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(connection))!
        check(state.control?.canSet == true && state.control?.role == "ownerDevice", "현재 TLS 승인 기기에만 제어 capability 제공")
        let off = coordinator.request(false, from: connection)
        let released = coordinator.receive(off.rawRequest, from: connection)!
        check(released.accepted && released.operationState == .applied && released.code == .applied &&
              released.state.phase == .inactive && !released.state.requested, "정확한 물리 해제 뒤에만 off applied")
        check(coordinator.effects.suffix(2) == ["release", "inactive"] && !coordinator.surface,
              "원격 off가 자기 표면과 Sentry 저널만 해제")
        check(coordinator.connections.count == 1 && released.state.control?.manualIntent == .off,
              "off 뒤 기존 연결과 명시 의도 보존")
        let inactiveProof = coordinator.sentry!.forwardingProof()!
        coordinator.audioVerified = false
        check(coordinator.sentry!.forwardingProof() == nil && !coordinator.sentry!.forwardingProofCurrent(inactiveProof),
              "명시 off도 전체 로컬 음소거 증명 없이 음성 권한을 만들지 않음")
        coordinator.audioVerified = true
        check(coordinator.sentry!.forwardingProof() != nil,
              "명시 off는 별도 입출력 보호 증명을 유지한 음성 경로를 허용")
        let effects = coordinator.effects
        check(coordinator.receive(off.rawRequest, from: connection)?.operationState == .applied &&
              coordinator.effects == effects, "같은 원문 재조회는 표면 효과를 반복하지 않음")
        let conflict = try! SentryControlRequest(requestID: off.requestID, hostBootID: off.hostBootID,
            sessionID: off.sessionID, revision: off.revision, authorizationGeneration: off.authorizationGeneration, desired: true)
        check(coordinator.receive(conflict.rawRequest, from: connection)?.code == .requestConflict &&
              coordinator.effects == effects, "동일 요청 ID의 변경 본문 거절")
        coordinator.leave(connection)
        let next = NWConnection()
        coordinator.join(next, fingerprint: key)
        let reconnected = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(next))!
        check(!reconnected.requested && reconnected.control?.authorizationGeneration == state.control?.authorizationGeneration,
              "외부 재접속도 같은 승인 세대의 수동 off를 보존")
        check(coordinator.receive(off.rawRequest, from: next)?.operationState == .applied,
              "같은 승인 기기의 새 TLS 세션에서 이전 session 원문을 읽기 전용 조회")
        let on = coordinator.request(true, from: next)
        let waiting = coordinator.receive(on.rawRequest, from: next)!
        check(waiting.operationState == .pending && waiting.state.phase == .pending &&
              coordinator.server.sentryAdmission.allowsActions(ObjectIdentifier(next)),
              "물리 on 뒤 캡처가 없으면 선택 가능한 pending이며 적용 완료로 표시하지 않음")
        let immediateOff = coordinator.request(false, from: next)
        check(coordinator.receive(immediateOff.rawRequest, from: next)?.operationState == .applied,
              "영상 선택 전에도 새 명시 off가 pending on을 대체")
        check(coordinator.receive(on.rawRequest, from: next)?.operationState == .superseded,
              "다른 명시 전환 뒤 이전 on 조회는 최신 상태와 superseded를 반환")
        let capturedOn = coordinator.request(true, from: next)
        _ = coordinator.receive(capturedOn.rawRequest, from: next)
        coordinator.server.sentryAdmission.capture(UUID(), for: ObjectIdentifier(next))
        check(coordinator.receive(capturedOn.rawRequest, from: next)?.operationState == .applied,
              "실제 전송 경계가 제공한 캡처 세대 도착 뒤 같은 on 원문 조회 applied")
        let stale = coordinator.request(false, from: next)
        coordinator.server.sentryAdmission.capture(UUID(), for: ObjectIdentifier(next))
        let beforeStale = coordinator.effects
        check(coordinator.receive(stale.rawRequest, from: next)?.operationState == .unknown && coordinator.effects == beforeStale,
              "원장 밖 이전 CAS는 물리 효과 없이 결과 미확인 반환")
        coordinator.debt = true
        let blocked = coordinator.request(false, from: next)
        check(coordinator.receive(blocked.rawRequest, from: next)?.operationState == .rejected && coordinator.surface,
              "입력 부채가 정리되지 않으면 보호를 실제 해제하지 않음")
        coordinator.debt = false
        coordinator.remote?.keys.remove(key)
        coordinator.server.sentryAdmission.revokeControl(forDeviceID: key.map { String(format: "%02x", $0) }.joined())
        let beforeRevoked = coordinator.effects
        check(coordinator.receive(off.rawRequest, from: next) == nil && coordinator.effects == beforeRevoked,
              "현재 trust 철회 뒤 과거 원문도 결과 oracle이나 물리 효과를 만들지 않음")
        check(!coordinator.sentry!.forwardingProofCurrent(inactiveProof), "신뢰 철회는 이전 명시 off의 음성 보호 증명도 무효화")
        let plain = ControlCoordinator(), unencrypted = NWConnection()
        plain.join(unencrypted, fingerprint: key, encrypted: false)
        check(plain.server.sentryAdmission.status(for: ObjectIdentifier(unencrypted))?.control == nil &&
              plain.receive(off.rawRequest, from: unencrypted) == nil, "비암호화 연결에는 제어 권한과 상태 응답을 주지 않음")
        let foreign = ControlCoordinator(), unpaired = NWConnection()
        foreign.join(unpaired, fingerprint: key, paired: false)
        check(foreign.server.sentryAdmission.status(for: ObjectIdentifier(unpaired))?.control == nil &&
              foreign.receive(off.rawRequest, from: unpaired) == nil, "미등록 TLS 기기의 자기 주장을 인가로 쓰지 않음")
        print("SENTRY_HOST_CONTROL \(count) actual event/HAL/voice/UI effects 0")
    }
}
