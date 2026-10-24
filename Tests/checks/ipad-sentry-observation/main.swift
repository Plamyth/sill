import Foundation
import StreamProtocol

var checks = 0
func check(_ passed: @autoclosure () -> Bool, _ label: String) {
    precondition(passed(), label)
    checks += 1
    print("PASS \(label)")
}
func object(_ data: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
let boot = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
let session = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
let revision = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
let auth = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
let nextSession = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
let nextAuth = "ffffffff-ffff-4fff-8fff-ffffffffffff"
let peer = NWConnection(), other = NWConnection()
let peerID = ObjectIdentifier(peer), otherID = ObjectIdentifier(other)
let binding = IPadSentryControl.Binding(macID: "fixtureMac", hostPin: peer.pin, deviceFingerprint: DeviceIdentity.fingerprint!)

func state(_ phase: SentryState.Phase = .inactive, requested: Bool? = nil, bootID: UUID = boot,
           sessionID: UUID = session, revisionID: UUID = revision, control: Bool = true) -> [String: Any] {
    var result = object(Wire.encode(SentryState(hostBootID: bootID, sessionID: sessionID, revision: revisionID,
        requested: requested ?? (phase != .inactive), phase: phase, limitations: [])))
    if control {
        result["control"] = ["version": 2, "role": "ownerDevice", "authorizationGeneration": auth,
                             "canSet": true, "manualIntent": "automatic"] as [String: Any]
    }
    return result
}
func catalog(_ sentry: Any?) -> Data {
    let epoch = VideoEpoch(generation: "video-generation", source: .desktop,
        geometry: .init(x: 0, y: 0, width: 1280, height: 720), width: 1280, height: 720)
    var result = object(Wire.encode(WindowList(macName: "격리 시험", windows: [], active: .desktop,
        launchID: "catalog-launch", inputGeneration: "input-generation", presentationInput: 1, videoEpoch: epoch)))
    result["sentry"] = sentry
    return json(result)
}
func reply(_ control: IPadSentryControl, _ operation: String, _ state: [String: Any], accepted: Bool = true,
           code: String? = nil) -> Data {
    json(["version": 2, "requestID": object(control.originalRequest!)["requestID"]!, "accepted": accepted,
          "operationState": operation, "code": code ?? "SENTRY_" + operation.uppercased(), "state": state])
}
final class MemoryStore {
    var data: Data?
    var fail = false
    var dropWrite = false
    var saves = 0
    enum Failure: Error { case failed }
    var store: IPadSentryControl.Store {
        .init(load: { self.data }, save: { data in
            self.saves += 1
            if self.fail { throw Failure.failed }
            if !self.dropWrite { self.data = data }
        })
    }
}
func observe(_ control: inout IPadSentryControl, _ state: [String: Any] = state(), on peer: NWConnection = peer,
             binding: IPadSentryControl.Binding? = binding) {
    var observation = IPadSentryObservation()
    observation.bind(ObjectIdentifier(peer))
    observation.observe(catalog: catalog(state), from: ObjectIdentifier(peer))
    control.observe(catalog: catalog(state), observation: observation, binding: binding, from: ObjectIdentifier(peer))
}
func ready(_ memory: MemoryStore) -> IPadSentryControl {
    var result = IPadSentryControl(store: memory.store)
    result.bind(peerID)
    observe(&result)
    return result
}
func perform(_ control: inout IPadSentryControl, desired: Bool = false) -> Data? {
    control.perform(desired: desired, binding: binding, from: peerID, now: 100)
}
func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }

var observation = IPadSentryObservation()
check(observation.status == .unknown && observation.statusText == "호스트 보고: 미확인", "최초 미확인")
observation.bind(peerID)
for (phase, text) in [(SentryState.Phase.inactive, "꺼짐"), (.pending, "보호 준비"),
                      (.userSessionProtected, "켜짐·보호 확인"), (.blocked, "보호 확인 실패")] {
    observation.observe(catalog: catalog(state(phase)), from: peerID)
    check(observation.statusText == "호스트 보고: " + text, "실제 phase 표시 \(phase)")
    observation.observe(catalog: catalog(state(phase, requested: phase == .inactive)), from: peerID)
    check(observation.status == .unknown, "requested/phase 불일치 \(phase)")
}
var invalid: [[String: Any]] = []
for (key, value) in [("version", 2 as Any), ("version", "1" as Any), ("phase", "future" as Any),
                     ("sessionID", NSNull()), ("hostBootID", "broken" as Any), ("revision", NSNull()),
                     ("limitations", 1 as Any), ("requested", "true" as Any)] {
    var valueState = state(); valueState[key] = value; invalid.append(valueState)
}
var missing = state(); missing["requested"] = nil; invalid.append(missing)
for (index, damaged) in invalid.enumerated() {
    observation.observe(catalog: catalog(damaged), from: peerID)
    check(observation.status == .unknown, "손상/미지원 보고 미확인 \(index)")
}
for field: Any? in [nil, NSNull(), "broken", 42, ["not": "sentry"]] {
    let data = catalog(field)
    observation.observe(catalog: data, from: peerID)
    check(observation.status == .unknown, "missing/null/malformed Sentry 분리")
    let list = Wire.decode(WindowList.self, from: data)!
    check(list.active == .desktop && list.videoEpoch?.isValid == true && list.inputGeneration == "input-generation", "실제 WindowList/영상 catalog 디코드 계속")
}
observation.observe(catalog: Data("{".utf8), from: peerID)
check(observation.status == .unknown, "잘린 JSON 미확인")
observation.observe(catalog: catalog(state(.userSessionProtected)), from: peerID)
let reported = observation.status
observation.observe(catalog: catalog(state()), from: otherID)
check(observation.status == reported, "다른 peer 보고 무시")
observation.bind(otherID)
check(observation.status == .unknown, "peer 교체 즉시 미확인, 꺼짐 아님")
observation.observe(catalog: catalog(state(.userSessionProtected)), from: peerID)
check(observation.status == .unknown, "늦은 old peer 보고 무시")
observation.observe(catalog: catalog(state()), from: otherID)
check(observation.statusText == "호스트 보고: 꺼짐", "new peer의 수신한 off 보고")
observation.observe(catalog: catalog(state(.pending, sessionID: nextSession)), from: otherID)
check(observation.status == .unknown, "같은 peer session 충돌")
observation.observe(catalog: catalog(state()), from: otherID)
check(observation.status == .unknown, "scope 충돌 후 원 scope도 미확인 유지")
observation.bind(nil); observation.bind(peerID)
observation.observe(catalog: catalog(state()), from: peerID)
observation.observe(catalog: catalog(state(bootID: nextSession)), from: peerID)
check(observation.status == .unknown, "같은 peer boot 충돌")
observation.bind(nil); observation.bind(peerID)
for id in [nextSession, revision, boot] {
    observation.observe(catalog: catalog(state(.pending, revisionID: id)), from: peerID)
    check(observation.statusText == "호스트 보고: 보호 준비", "revision UUID 순서 판단 없이 수신 보고만 표시")
}

for altered: Any? in [nil, NSNull(), "bad", ["version": 3],
                     ["version": 2, "role": "otherDevice", "authorizationGeneration": auth, "canSet": true, "manualIntent": "off"],
                     ["version": 2, "role": "ownerDevice", "authorizationGeneration": auth, "canSet": false, "manualIntent": "off"],
                     ["version": 2, "role": "ownerDevice", "authorizationGeneration": auth.uppercased(), "canSet": true, "manualIntent": "off"]] {
    let memory = MemoryStore(); var control = ready(memory)
    var report = state(); report["control"] = altered
    observe(&control, report)
    check(!control.canSet && perform(&control) == nil && memory.saves == 0, "무효 control은 조회만, off 송신 0")
    var readOnly = IPadSentryObservation(); readOnly.bind(peerID)
    readOnly.observe(catalog: catalog(report), from: peerID)
    check(readOnly.statusText == "호스트 보고: 꺼짐", "control 손상과 기존 state 조회 분리")
}
for dropping in [false, true] {
    let memory = MemoryStore(); memory.fail = !dropping; memory.dropWrite = dropping
    var control = ready(memory)
    check(perform(&control) == nil && control.originalRequest == nil && control.problem != nil, "저장 실패/readback 실패 시 효과 명령 0")
}
let memory = MemoryStore(); var control = ready(memory)
let packet = perform(&control)!
check(memory.saves == 1 && memory.data != nil, "송신 bytes 반환 전에 내구 저장 완료")
check(packet.first == 213 && StreamMessage.parseHeader(packet)?.kind == .activateSentry, "정상 activateSentry kind213 packet")
check(Data(packet.dropFirst(StreamMessage.headerLength)) == control.originalRequest, "packet payload 원본문 byte 일치")
let persisted = object(memory.data!)
check(Set(persisted.keys) == ["binding", "rawRequest"] && Set((persisted["binding"] as! [String: Any]).keys) == ["macID", "hostPin", "deviceFingerprint"], "저장 필드는 public binding과 raw bytes뿐")
var maximum = control.originalRequest!
maximum.append(Data(repeating: 32, count: 512 - maximum.count))
check(IPadSentryControl.packet(maximum)?.count == 526, "request cap512 byte 경계 허용")
maximum.append(32)
check(IPadSentryControl.packet(maximum) == nil, "request513 byte 거부")
let request = object(control.originalRequest!)
check(Set(request.keys) == ["version", "requestID", "hostBootID", "sessionID", "revision", "authorizationGeneration", "desired"], "요청 exact field set")
check(request["desired"] as? Bool == false && request["version"] as? Int == 2, "명시 off desired false version2")
for key in ["requestID", "hostBootID", "sessionID", "revision", "authorizationGeneration"] {
    let value = request[key] as! String
    check(value == value.lowercased() && UUID(uuidString: value) != nil, "UUID lowercase canonical \(key)")
}
check(control.originalRequest!.count <= 512 && StreamMessage.clientPayloadLimit(for: .activateSentry) == 512 && StreamMessage.hostPayloadLimit(for: .sentryState) == 4096, "canonical request512 reply4096 상한")
check(StreamMessage.clientPayloadLimit(for: .sentryState) == -1 && StreamMessage.hostPayloadLimit(for: .activateSentry) == -1, "방향 반대 메시지 거부")
check(perform(&control) == nil && control.query(binding: binding, from: peerID, now: 101) == nil && memory.saves == 1, "pending 중 중복 및 새 ID 0")
check(control.receive(reply(control, "pending", state(.pending)), binding: binding, from: peerID) != nil && control.phase == .pending && !control.canSet, "accepted pending은 완료 아님")
let raw = control.originalRequest!
check(control.query(binding: binding, from: peerID, now: 102) == packet && control.originalRequest == raw, "수동 조회 원문·requestID·packet 정확 재사용")
control.checkTimeout(now: 112)
check(control.phase == .unknown && control.originalRequest == raw && !control.canSet && control.canQuery, "timeout은 unknown 원문 보존, 새 명령 0")
var restored = IPadSentryControl(store: memory.store)
check(restored.phase == .unknown && restored.originalRequest == raw && !restored.canSet && !restored.canQuery, "앱 재실행 원문과 binding 복원, 자동 송신 0")
restored.bind(otherID)
observe(&restored, state(sessionID: nextSession), on: other)
check(restored.canQuery && !restored.canSet, "같은 boot/device/auth의 새 session 수동 조회만")
check(restored.query(binding: binding, from: otherID, now: 200) == packet, "새 session/revision으로 원문 수정 0")
check(restored.receive(reply(restored, "applied", state(sessionID: nextSession)), binding: binding, from: peerID) == nil && restored.phase == .pending, "late old peer receipt 현재 작업 변경 0")
check(restored.receive(reply(restored, "applied", state(sessionID: nextSession)), binding: binding, from: otherID) != nil && restored.phase == .applied, "새 session 조회 off 실제 readback만 applied")
check(restored.originalRequest == raw && restored.canSet, "종결 후 원문 보존, 다음 명시 작업 허용")
let oldRequestID = UUID(uuidString: object(raw)["requestID"] as! String)!
check(restored.perform(desired: true, binding: binding, from: otherID, now: 210, requestID: oldRequestID) == nil && restored.originalRequest == raw, "같은 requestID 다른 desired 로컬 재발행 차단")
var peerGuard = ready(MemoryStore())
check(peerGuard.perform(desired: false, binding: nil, from: otherID, now: 100) == nil && peerGuard.canSet, "old peer의 action이 현재 권한 context 변경 0")

for desired in [false, true] {
    for (operation, code, accepted, resultState, completes) in [
        ("applied", "SENTRY_APPLIED", true, state(desired ? .userSessionProtected : .inactive), true),
        ("applied", "SENTRY_APPLIED", false, state(desired ? .userSessionProtected : .inactive), false),
        ("applied", "SENTRY_APPLIED", true, state(.pending), false),
        ("pending", "SENTRY_PENDING", true, state(.pending), false),
        ("unknown", "SENTRY_UNKNOWN", true, state(), false),
        ("superseded", "SENTRY_SUPERSEDED", false, state(), false),
        ("Applied", "SENTRY_APPLIED", true, state(), false)] {
        let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested, desired: desired)
        let original = tested.originalRequest
        _ = tested.receive(reply(tested, operation, resultState, accepted: accepted, code: code), binding: binding, from: peerID)
        check((tested.phase == .applied) == completes && tested.originalRequest == original, "desired \(desired) \(operation)/\(accepted) readback 완료 구분")
    }
}
for code in ["SENTRY_UNSUPPORTED", "SENTRY_NOT_AUTHORIZED", "SENTRY_STALE_STATE", "SENTRY_REQUEST_CONFLICT", "SENTRY_BUSY", "SENTRY_CONTROL_FAILED", "SENTRY_TARGET_UNCONFIRMED", "SENTRY_SUPERSEDED"] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested)
    _ = tested.receive(reply(tested, "rejected", state(), accepted: false, code: code), binding: binding, from: peerID)
    check(tested.phase == .rejected(code) && tested.originalRequest != nil && tested.canSet, "고정 거절 코드와 원문 보존 \(code)")
}
for mutation in ["version", "state-version", "state-inconsistent", "missing-code", "null-code", "number-code", "wrong-request", "uppercase-request", "wrong-boot", "wrong-session", "wrong-auth", "unknown-control", "oversize", "malformed"] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested)
    let original = tested.originalRequest!
    var value = object(reply(tested, "applied", state()))
    var report = value["state"] as! [String: Any]
    switch mutation {
    case "version": value["version"] = 1
    case "state-version": report["version"] = 2
    case "state-inconsistent": report["requested"] = true
    case "missing-code": value["code"] = nil
    case "null-code": value["code"] = NSNull()
    case "number-code": value["code"] = 200
    case "wrong-request": value["requestID"] = nextSession.uuidString.lowercased()
    case "uppercase-request": value["requestID"] = (value["requestID"] as! String).uppercased()
    case "wrong-boot": report["hostBootID"] = nextSession.uuidString
    case "wrong-session": report["sessionID"] = nextSession.uuidString
    case "wrong-auth": var c = report["control"] as! [String: Any]; c["authorizationGeneration"] = nextAuth; report["control"] = c
    case "unknown-control": report["control"] = ["version": 3]
    case "oversize": value["padding"] = String(repeating: "x", count: 4096)
    default: break
    }
    value["state"] = report
    let bytes = mutation == "malformed" ? Data("{".utf8) : json(value)
    check(tested.receive(bytes, binding: binding, from: peerID) == nil && tested.phase == .unknown && tested.originalRequest == original && !tested.canSet, "무효 응답 unknown 원문 보존 \(mutation)")
}
for change in ["host", "pin", "device", "boot", "authorization", "nil-trust"] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested); tested.bind(nil); tested.bind(otherID)
    var currentBinding: IPadSentryControl.Binding? = binding
    var report = state(sessionID: nextSession)
    switch change {
    case "host": currentBinding = .init(macID: "another", hostPin: binding.hostPin, deviceFingerprint: binding.deviceFingerprint)
    case "pin": currentBinding = .init(macID: binding.macID, hostPin: Data(repeating: 3, count: 32), deviceFingerprint: binding.deviceFingerprint)
    case "device": currentBinding = .init(macID: binding.macID, hostPin: binding.hostPin, deviceFingerprint: Data(repeating: 3, count: 32))
    case "boot": report["hostBootID"] = nextSession.uuidString
    case "authorization": var c = report["control"] as! [String: Any]; c["authorizationGeneration"] = nextAuth; report["control"] = c
    default: currentBinding = nil
    }
    observe(&tested, report, on: other, binding: currentBinding)
    check(tested.phase == .unknown && tested.originalRequest != nil && !tested.canSet && !tested.canQuery && tested.query(binding: currentBinding, from: otherID, now: 100) == nil, "binding 변경 old pending unknown 유지·신규 명시도 차단 \(change)")
}

let clientStore = MemoryStore(), client = StreamClient(store: clientStore.store)
client.connection = peer; client.sentryObservation.bind(peerID); client.sentryControl.bind(peerID)
check(client.sentryObservation.status == .unknown && !client.sentryControl.canSet, "frontend 최초 catalog 전 상태 미확인·버튼 비가용")
client.observeIPadSentry(catalog: catalog(state()), from: peer)
check(client.sentryObservation.statusText == "호스트 보고: 꺼짐" && client.sentryControl.canSet && peer.sent.isEmpty, "실제 frontend 최초 catalog 한 번으로 상태·버튼 활성화, 자동 send 0")
client.setIPadSentry(desired: false)
check(peer.sent.count == 1 && clientStore.data != nil && object(Data(peer.sent[0].dropFirst(14)))["desired"] as? Bool == false, "실제 명시 off 함수가 저장 후 정확 packet 송신")
client.setIPadSentry(desired: true)
check(peer.sent.count == 1, "실제 frontend pending duplicate send 0")
client.receiveIPadSentry(reply(client.sentryControl, "applied", state()), from: peer); pump()
check(client.sentryControl.phase == .applied && client.sentryObservation.statusText == "호스트 보고: 꺼짐", "실제 kind214 main 갱신 및 off readback")
client.setIPadSentry(desired: true)
check(peer.sent.count == 2 && object(Data(peer.sent[1].dropFirst(14)))["desired"] as? Bool == true, "실제 명시 on 함수의 desired true")
client.receiveIPadSentry(reply(client.sentryControl, "applied", state(.userSessionProtected)), from: peer); pump()
check(client.sentryControl.phase == .applied && client.sentryObservation.statusText == "호스트 보고: 켜짐·보호 확인", "실제 명시 on 적용 readback")
for loss in ["TLS", "pin", "device", "revoked", "registration", "connected"] {
    let memory = MemoryStore(), tested = StreamClient(store: memory.store), connection = NWConnection()
    tested.connection = connection; tested.sentryObservation.bind(ObjectIdentifier(connection)); tested.sentryControl.bind(ObjectIdentifier(connection))
    tested.observeIPadSentry(catalog: catalog(state()), from: connection)
    switch loss {
    case "TLS": connection.alpn = nil
    case "pin": connection.pin = Data(repeating: 5, count: 32)
    case "device": DeviceIdentity.fingerprint = nil
    case "revoked": tested.savedMacs[0].revoked = true
    case "registration": tested.session?.macID = nil
    default: tested.connected = false
    }
    tested.setIPadSentry(desired: false)
    check(connection.sent.isEmpty && memory.saves == 0, "실제 frontend trust 재확인 송신 차단 \(loss)")
    DeviceIdentity.fingerprint = binding.deviceFingerprint
}

for size in [0, 1, 4096, 4097] {
    let connection = NWConnection()
    let payload = Data(repeating: 0x78, count: size)
    connection.wire = StreamMessage(kind: .sentryState, timestamp: 0, isKeyframe: false, payload: payload).serialized()
    var messages = 0, tooBig = false
    MessageReader(connection: connection, stillReads: { true }, onBytes: { _ in }, onMessage: { header, data in
        check(header.kind == .sentryState && data.count == size, "실제 reader kind214 payload")
        messages += 1
    }, onEnd: { end in if case .tooBig = end { tooBig = true } }).start()
    check(size <= 4096 ? messages == 1 && !tooBig : messages == 0 && tooBig && connection.wire.count == size, "actual reader reply cap\(size) 헤더에서 조기 거부")
}
let reader = NWConnection()
reader.wire = StreamMessage(kind: .sentryState, timestamp: 0, isKeyframe: false, payload: Data("{".utf8)).serialized()
reader.wire += StreamMessage(kind: .windowList, timestamp: 0, isKeyframe: false, payload: catalog("broken")).serialized()
reader.wire += StreamMessage(kind: .frame, timestamp: 0, isKeyframe: true, payload: Data([1, 2, 3])).serialized()
var kinds: [StreamMessageKind] = []
MessageReader(connection: reader, stillReads: { true }, onBytes: { _ in }, onMessage: { header, data in
    kinds.append(header.kind)
    if header.kind == .sentryState { client.receiveIPadSentry(data, from: peer) }
    if header.kind == .windowList { check(Wire.decode(WindowList.self, from: data)?.videoEpoch?.isValid == true, "reader 뒤 catalog 영상 epoch 디코드 계속") }
}, onEnd: { _ in }).start()
pump()
check(kinds == [.sentryState, .windowList, .frame], "malformed Sentry 뒤 실제 reader 영상 framing 계속")
check(client.sentryControl.phase == .unknown && client.sentryControl.originalRequest != nil, "malformed kind214 unknown 보존")
print("소비자 회귀 \(checks)/\(checks) 통과")
