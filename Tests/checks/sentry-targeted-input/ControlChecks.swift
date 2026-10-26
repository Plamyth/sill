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
@MainActor final class ReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
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
    var releaseGate: ReleaseGate?
    init() {
        sentry = HostSentry(admission: server.sentryAdmission, initiallyLatched: false, persistenceHealthy: true,
            persist: { [unowned self] value in effects.append(value.rawValue); return true },
            surfaces: .init(engage: { [unowned self] in surface = true; effects.append("engage"); return true },
                verify: { [unowned self] in surface }, release: { [unowned self] _, current in
                    effects.append("release")
                    if let releaseGate { await releaseGate.wait() }
                    guard current() else { return false }
                    if releaseOK { surface = false }; return releaseOK
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
    func receive(_ payload: Data, from connection: NWConnection) async -> SentryControlResponse? {
        let count = server.messages.count
        await activateSentry(.init(kind: .activateSentry, timestamp: 1, isKeyframe: false, payload: payload), from: connection)
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
    @MainActor static func main() async {
        await delayedControlChecks()
        await reconnectedControlChecks()
        let key = Data(repeating: 3, count: 32), connection = NWConnection(), coordinator = ControlCoordinator()
        coordinator.join(connection, fingerprint: key)
        let state = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(connection))!
        check(state.control?.canSet == true && state.control?.role == "ownerDevice", "현재 TLS 승인 기기에만 제어 capability 제공")
        let off = coordinator.request(false, from: connection)
        let released = (await coordinator.receive(off.rawRequest, from: connection))!
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
        check(await coordinator.receive(off.rawRequest, from: connection)?.operationState == .applied &&
              coordinator.effects == effects, "같은 원문 재조회는 표면 효과를 반복하지 않음")
        let conflict = try! SentryControlRequest(requestID: off.requestID, hostBootID: off.hostBootID,
            sessionID: off.sessionID, revision: off.revision, authorizationGeneration: off.authorizationGeneration, desired: true)
        check(await coordinator.receive(conflict.rawRequest, from: connection)?.code == .requestConflict &&
              coordinator.effects == effects, "동일 요청 ID의 변경 본문 거절")
        coordinator.leave(connection)
        let next = NWConnection()
        coordinator.join(next, fingerprint: key)
        let reconnected = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(next))!
        check(!reconnected.requested && reconnected.control?.authorizationGeneration == state.control?.authorizationGeneration,
              "외부 재접속도 같은 승인 세대의 수동 off를 보존")
        check(await coordinator.receive(off.rawRequest, from: next)?.operationState == .applied,
              "같은 승인 기기의 새 TLS 세션에서 이전 session 원문을 읽기 전용 조회")
        let on = coordinator.request(true, from: next)
        let waiting = (await coordinator.receive(on.rawRequest, from: next))!
        check(waiting.operationState == .pending && waiting.state.phase == .pending &&
              coordinator.server.sentryAdmission.allowsActions(ObjectIdentifier(next)),
              "물리 on 뒤 캡처가 없으면 선택 가능한 pending이며 적용 완료로 표시하지 않음")
        let immediateOff = coordinator.request(false, from: next)
        check(await coordinator.receive(immediateOff.rawRequest, from: next)?.operationState == .applied,
              "영상 선택 전에도 새 명시 off가 pending on을 대체")
        check(await coordinator.receive(on.rawRequest, from: next)?.operationState == .superseded,
              "다른 명시 전환 뒤 이전 on 조회는 최신 상태와 superseded를 반환")
        let capturedOn = coordinator.request(true, from: next)
        _ = await coordinator.receive(capturedOn.rawRequest, from: next)
        coordinator.server.sentryAdmission.capture(UUID(), for: ObjectIdentifier(next))
        check(await coordinator.receive(capturedOn.rawRequest, from: next)?.operationState == .applied,
              "실제 전송 경계가 제공한 캡처 세대 도착 뒤 같은 on 원문 조회 applied")
        let stale = coordinator.request(false, from: next)
        coordinator.server.sentryAdmission.capture(UUID(), for: ObjectIdentifier(next))
        let beforeStale = coordinator.effects
        check(await coordinator.receive(stale.rawRequest, from: next)?.operationState == .unknown && coordinator.effects == beforeStale,
              "원장 밖 이전 CAS는 물리 효과 없이 결과 미확인 반환")
        coordinator.debt = true
        let blocked = coordinator.request(false, from: next)
        check(await coordinator.receive(blocked.rawRequest, from: next)?.operationState == .rejected && coordinator.surface,
              "입력 부채가 정리되지 않으면 보호를 실제 해제하지 않음")
        coordinator.debt = false
        coordinator.remote?.keys.remove(key)
        coordinator.server.sentryAdmission.revokeControl(forDeviceID: key.map { String(format: "%02x", $0) }.joined())
        let beforeRevoked = coordinator.effects
        check(await coordinator.receive(off.rawRequest, from: next) == nil && coordinator.effects == beforeRevoked,
              "현재 trust 철회 뒤 과거 원문도 결과 oracle이나 물리 효과를 만들지 않음")
        check(!coordinator.sentry!.forwardingProofCurrent(inactiveProof), "신뢰 철회는 이전 명시 off의 음성 보호 증명도 무효화")
        let plain = ControlCoordinator(), unencrypted = NWConnection()
        plain.join(unencrypted, fingerprint: key, encrypted: false)
        let plainResponse = await plain.receive(off.rawRequest, from: unencrypted)
        check(plain.server.sentryAdmission.status(for: ObjectIdentifier(unencrypted))?.control == nil &&
              plainResponse == nil, "비암호화 연결에는 제어 권한과 상태 응답을 주지 않음")
        let foreign = ControlCoordinator(), unpaired = NWConnection()
        foreign.join(unpaired, fingerprint: key, paired: false)
        let foreignResponse = await foreign.receive(off.rawRequest, from: unpaired)
        check(foreign.server.sentryAdmission.status(for: ObjectIdentifier(unpaired))?.control == nil &&
              foreignResponse == nil, "미등록 TLS 기기의 자기 주장을 인가로 쓰지 않음")
        print("SENTRY_HOST_CONTROL \(count) actual event/HAL/voice/UI effects 0")
    }
}

extension ControlChecks {
    @MainActor static func reconnectedControlChecks() async {
        for initiallyOn in [false, true] {
            for trustRevoked in [false, true] {
                let coordinator = ControlCoordinator(), old = NWConnection(), current = NWConnection()
                let gate = ReleaseGate(), key = Data(repeating: 12, count: 32)
                coordinator.join(old, fingerprint: key)
                if initiallyOn {
                    _ = await coordinator.receive(coordinator.request(true, from: old).rawRequest, from: old)
                }
                coordinator.releaseGate = gate
                let off = coordinator.request(false, from: old)
                let task = Task { await coordinator.receive(off.rawRequest, from: old) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
                check(gate.entered, "구 연결의 OFF가 비동기 해제 대기에 도달")
                coordinator.leave(old)
                coordinator.join(current, fingerprint: key)
                let before = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(current))!
                check(before.control != nil && before.sessionID != off.sessionID,
                      "동일 기기의 새 연결은 별도 세션과 현재 제어 권한 보유")
                if trustRevoked { coordinator.remote?.keys.remove(key) }
                gate.release()
                check(await task.value == nil, "구 연결의 늦은 완료는 응답을 보내지 않음")
                let after = coordinator.server.sentryAdmission.status(for: ObjectIdentifier(current))!
                if trustRevoked {
                    let revokedResponse = await coordinator.receive(off.rawRequest, from: current)
                    check(after.control == nil && revokedResponse == nil,
                          "실제 paired 신뢰 철회는 새 연결까지 제어와 원문 조회 차단")
                } else {
                    check(after.sessionID == before.sessionID && after.control == before.control,
                          "구 연결의 늦은 완료가 같은 기기의 새 연결 권한을 철회하지 않음")
                    let next = coordinator.request(true, from: current)
                    check(await coordinator.receive(next.rawRequest, from: current)?.accepted == true,
                          "새 연결은 현재 세대의 명시 요청을 계속 처리")
                }
            }
        }
    }

    @MainActor static func delayedControlChecks() async {
        for (outcome, initiallyOn) in [("ack", false), ("owner", false), ("cancel", false),
                                     ("ack", true), ("owner", true), ("cancel", true)] {
            let coordinator = ControlCoordinator(), connection = NWConnection(), gate = ReleaseGate()
            let key = Data(repeating: 9, count: 32)
            coordinator.join(connection, fingerprint: key)
            if initiallyOn {
                _ = await coordinator.receive(coordinator.request(true, from: connection).rawRequest, from: connection)
            }
            coordinator.effects.removeAll()
            coordinator.releaseGate = gate
            let off = coordinator.request(false, from: connection)
            let task = Task { await coordinator.receive(off.rawRequest, from: connection) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !gate.entered && ContinuousClock.now < deadline { await Task.yield() }
            check(gate.entered, "원격 off가 실제 surface ACK를 기다리는 지점에 도달")
            let pending = await coordinator.receive(off.rawRequest, from: connection)
            check(pending?.operationState == .pending && pending?.state.requested == true &&
                  pending?.state.phase == .pending && coordinator.effects == [initiallyOn ? "releasing" : "inactive", "release"],
                  "대기 중 동일 원문 request 재조회는 pending·requested=true만 반환하고 효과 반복0")
            let concurrent = coordinator.request(false, from: connection)
            let rejected = await coordinator.receive(concurrent.rawRequest, from: connection)
            check(rejected?.operationState != .applied &&
                  coordinator.effects == [initiallyOn ? "releasing" : "inactive", "release"],
                  "재진입 off는 기존 ticket을 빼앗거나 inactive를 먼저 게시하지 않음")
            if outcome == "owner" { coordinator.remote?.keys.remove(key) }
            if outcome == "cancel" { task.cancel() }
            gate.release()
            let result = await task.value
            if outcome == "ack" {
                check(result?.operationState == .applied && result?.state.phase == .inactive &&
                      result?.state.requested == false && coordinator.effects == [initiallyOn ? "releasing" : "inactive", "release", "inactive"],
                      "동일 ticket의 실제 ACK 뒤 terminal applied와 inactive를 함께 반환")
                let effects = coordinator.effects
                let recovered = await coordinator.receive(off.rawRequest, from: connection)
                check(recovered?.operationState == .applied && coordinator.effects == effects,
                      "terminal 응답 유실도 동일 원문 query로 회수하며 재해제0")
                let nextGate = ReleaseGate()
                coordinator.releaseGate = nextGate
                let alreadyOff = coordinator.request(false, from: connection)
                let repeated = Task { await coordinator.receive(alreadyOff.rawRequest, from: connection) }
                while !nextGate.entered { await Task.yield() }
                let stillPending = await coordinator.receive(alreadyOff.rawRequest, from: connection)
                check(stillPending?.state.requested == true && stillPending?.state.phase == .pending &&
                      stillPending?.operationState == .pending,
                      "이미 inactive였던 OFF도 새 해제 ACK 전에는 requested=false를 먼저 게시하지 않음")
                nextGate.release()
                check(await repeated.value?.operationState == .applied,
                      "새 OFF ticket도 자기 ACK 후에만 terminal 반환")
            } else {
                check(result?.operationState != .applied &&
                      coordinator.effects.contains("latched") == initiallyOn && coordinator.surface == initiallyOn &&
                      coordinator.server.sentryAdmission.isRequested == initiallyOn,
                      "\(outcome) 뒤 늦은 ACK는 owner/current를 넘지 못하고 기존 선택을 보존")
            }
        }
    }
}
