import Foundation
import CryptoKit
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
for (phase, text) in [(SentryState.Phase.inactive, "꺼짐"), (.pending, "보호 전환 중"),
                      (.userSessionProtected, "켜짐·보호 확인"), (.blocked, "보호 확인 실패")] {
    observation.observe(catalog: catalog(state(phase)), from: peerID)
    check(observation.statusText == "호스트 보고: " + text, "실제 phase 표시 \(phase)")
    observation.observe(catalog: catalog(state(phase, requested: phase == .inactive)), from: peerID)
    if phase == .pending {
        check(observation.statusText == "호스트 보고: 보호 전환 중", "Host prepared off pending/false 관찰 유지")
    } else {
        check(observation.status == .unknown, "requested/phase 불일치 \(phase)")
    }
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
    check(observation.statusText == "호스트 보고: 보호 전환 중", "revision UUID 순서 판단 없이 수신 보고만 표시")
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
check(Set(persisted.keys) == ["binding", "rawRequest", "ledgerAccepted"] && persisted["ledgerAccepted"] as? Bool == false && Set((persisted["binding"] as! [String: Any]).keys) == ["macID", "hostPin", "deviceFingerprint"], "저장은 기존 public binding·raw와 초기 false 접수 확인 값")
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
for code in ["SENTRY_UNSUPPORTED", "SENTRY_NOT_AUTHORIZED", "SENTRY_STALE_STATE", "SENTRY_REQUEST_CONFLICT", "SENTRY_BUSY", "SENTRY_CONTROL_FAILED", "SENTRY_TARGET_UNCONFIRMED"] {
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
func intentState(_ intent: String, phase: SentryState.Phase = .pending, requested: Bool = true,
                 sessionID: UUID = session, revisionID: UUID = revision) -> [String: Any] {
    var value = state(phase, requested: requested, sessionID: sessionID, revisionID: revisionID)
    var capability = value["control"] as! [String: Any]
    capability["manualIntent"] = intent
    value["control"] = capability
    return value
}
func savedRaw(_ memory: MemoryStore, key: String = "rawRequest") -> Data? {
    guard let data = memory.data, let value = object(data)[key] as? String else { return nil }
    return Data(base64Encoded: value)
}
func pendingOn(_ memory: MemoryStore) -> IPadSentryControl {
    var tested = ready(memory)
    _ = perform(&tested, desired: true)
    let raw = tested.originalRequest
    check(!tested.canSet(desired: false) && !tested.canSet(desired: true), "미응답 on은 새 on/off 모두 차단")
    let value = reply(tested, "pending", intentState("on"))
    check(tested.receive(value, binding: binding, from: peerID) != nil && tested.phase == .pending,
          "onPrepared 정책 응답은 applied가 아닌 pending")
    check(!tested.canSet(desired: true) && tested.canSet(desired: false) && tested.originalRequest == raw,
          "확인된 pending-on에서 명시 off만 허용")
    return tested
}

let hostFixtureData = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let hostFixture = object(hostFixtureData)
for name in ["On", "Off"] {
    let raw = Data((hostFixture["request" + name + "Raw"] as! String).utf8)
    let responseRaw = Data((hostFixture["response" + name + "Raw"] as! String).utf8)
    let request = try! SentryControlRequest(rawRequest: raw)
    let response = try! SentryControlResponse.decodePayload(responseRaw)
    check(request.rawRequest == raw && request.requestDigest == hostFixture["request" + name + "SHA256"] as! String,
          "Host 고정 원문 SHA와 공통 request decode \(name)")
    check(SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined() == request.requestDigest,
          "Host 원문 독립 SHA256 \(name)")
    check(response.requestID == request.requestID && response.operationState == .applied && response.accepted,
          "Host 원 response strict decode \(name)")
    let memory = MemoryStore()
    var tested = IPadSentryControl(store: memory.store)
    tested.bind(peerID)
    observe(&tested, object(try! JSONEncoder().encode(response.state)))
    let sent = tested.perform(desired: request.desired, binding: binding, from: peerID,
                              now: 100, requestID: request.requestID)
    check(sent == IPadSentryControl.packet(raw) && tested.originalRequest == raw && savedRaw(memory) == raw,
          "소비자 편의 init이 Host 원문 그대로 저장·송신 \(name)")
    check(tested.receive(responseRaw, binding: binding, from: peerID) == response.state && tested.phase == .applied,
          "Host 원 reply 소비자 end-to-end \(name)")
}

let legacyRaw = Data("""
{ "desired":true, "revision":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
"sessionID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "version":2,
"requestID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
"authorizationGeneration":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
"hostBootID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }
""".utf8)
let legacy = MemoryStore()
legacy.data = json(["binding": object(try! JSONEncoder().encode(binding)), "rawRequest": legacyRaw.base64EncodedString()])
var migrated = ready(legacy)
check(migrated.originalRequest == legacyRaw && migrated.phase == .unknown && legacy.saves == 0,
      "기존 2필드 Stored·임의순서 7필드 raw 마이그레이션은 재인코딩하지 않음")
check(migrated.query(binding: binding, from: peerID, now: 100) == nil && !migrated.canQuery,
      "접수 확인 없는 legacy 원문은 같은 session query 금지")
migrated.bind(otherID)
observe(&migrated, state(sessionID: nextSession), on: other)
check(migrated.query(binding: binding, from: otherID, now: 100) == IPadSentryControl.packet(legacyRaw),
      "legacy 새 session 조회도 공백·키순서·old session·ID까지 exact raw")

for accepted in [false, true] {
    for code in ["SENTRY_CONTROL_FAILED", "SENTRY_TARGET_UNCONFIRMED"] {
        var tested = ready(MemoryStore()); _ = perform(&tested, desired: true)
        let raw = tested.originalRequest
        let value = reply(tested, "rejected", state(.blocked), accepted: accepted, code: code)
        check((try? SentryControlResponse.decodePayload(value))?.operationState == .rejected,
              "공통 decoder 접수/미접수 후 실패 \(code)/\(accepted)")
        check(tested.receive(value, binding: binding, from: peerID) != nil && tested.phase == .rejected(code) &&
              tested.originalRequest == raw && tested.statusText.contains("호스트"),
              "accepted를 완료로 오인하지 않고 UI rejected·증거 유지 \(code)/\(accepted)")
    }
}

do {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested)
    let pendingFalse = reply(tested, "pending", intentState("automatic", requested: false))
    check((try? SentryControlResponse.decodePayload(pendingFalse))?.state.requested == false,
          "실제 Host statusLocked/prepareControl의 prepared-off strict decode")
    check(tested.receive(pendingFalse, binding: binding, from: peerID)?.phase == .pending && tested.phase == .pending &&
          !tested.canSet && tested.statusText.contains("대기"), "inactive에서 off prepared pending/false는 완료 아닌 대기")
    var observed = IPadSentryObservation(); observed.bind(peerID)
    observed.observe(catalog: catalog(intentState("automatic", requested: false)), from: peerID)
    check(observed.statusText == "호스트 보고: 보호 전환 중", "off 준비 카탈로그 중립 전환 문구")
    check(tested.receive(reply(tested, "applied", intentState("off", phase: .inactive, requested: false)),
                         binding: binding, from: peerID) != nil && tested.phase == .applied,
          "prepared-off 뒤 inactive/false만 applied")
}

do {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let onRaw = tested.originalRequest!
    check(tested.query(binding: binding, from: peerID, now: 110) == IPadSentryControl.packet(onRaw),
          "capture 전 같은 on 원문 수동 조회")
    _ = tested.receive(reply(tested, "applied", intentState("on", phase: .userSessionProtected)), binding: binding, from: peerID)
    check(tested.phase == .applied && tested.originalRequest == onRaw && tested.canSet,
          "capture 확인 후 같은 원문 조회가 나중 applied로 종결")
}

for code in ["SENTRY_BUSY", "SENTRY_STALE_STATE", "SENTRY_CONTROL_FAILED"] {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let onRaw = tested.originalRequest!
    let offPacket = perform(&tested)!, offRaw = tested.originalRequest!
    check(tested.priorRequest == onRaw && savedRaw(memory) == offRaw && savedRaw(memory, key: "priorRawRequest") == onRaw,
          "off packet 반환 전에 두 원문 영속 save/readback \(code)")
    check(!tested.canSet && perform(&tested, desired: true) == nil && perform(&tested) == nil,
          "off 미응답 동안 세 번째 명령 0 \(code)")
    _ = tested.receive(reply(tested, "rejected", intentState("on"), accepted: code == "SENTRY_CONTROL_FAILED", code: code),
                       binding: binding, from: peerID)
    check(tested.phase == .unknown && tested.originalRequest == onRaw && tested.priorRequest == offRaw &&
          tested.problem != nil && !tested.canSet && tested.canQuery,
          "off 거절 후 원 on exact 복원·오류 유지·조회만 가능 \(code)")
    check(savedRaw(memory) == onRaw && savedRaw(memory, key: "priorRawRequest") == offRaw,
          "복원도 두 원문 save/readback \(code)")
    var restarted = ready(memory)
    check(restarted.phase == .unknown && restarted.originalRequest == onRaw && restarted.priorRequest == offRaw && !restarted.canSet,
          "off 거절 복원 후 재시작 두 원문 유지 \(code)")
    check(restarted.query(binding: binding, from: peerID, now: 120) == IPadSentryControl.packet(onRaw) &&
          offPacket != IPadSentryControl.packet(onRaw), "재시작 후 수동 조회는 원 on bytes \(code)")
    _ = restarted.receive(reply(restarted, "superseded", intentState("off", phase: .inactive, requested: false)), binding: binding, from: peerID)
    check(restarted.phase == .superseded && restarted.originalRequest == onRaw && restarted.priorRequest == offRaw && restarted.canSet,
          "current original on 조회 superseded 종결·증거 보존 \(code)")
}

for dropping in [false, true] {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let onRaw = tested.originalRequest!; _ = perform(&tested); let offRaw = tested.originalRequest!
    memory.fail = !dropping; memory.dropWrite = dropping
    _ = tested.receive(reply(tested, "rejected", intentState("on"), accepted: false, code: "SENTRY_BUSY"), binding: binding, from: peerID)
    check(tested.phase == .unknown && tested.originalRequest == offRaw && tested.priorRequest == onRaw &&
          tested.problem?.contains("처리 중") == true && tested.problem?.contains("저장") == true && !tested.canSet,
          "원 on 복원 저장 실패/readback 실패는 off+on unknown·거절과저장오류 유지")
    let restarted = ready(memory)
    check(restarted.originalRequest == offRaw && restarted.priorRequest == onRaw && !restarted.canSet,
          "복원 실패 후 재시작에도 두 원문 유지·새 ID 0")
}

for dropping in [false, true] {
    let memory = MemoryStore(); var tested = pendingOn(memory); let onRaw = tested.originalRequest!
    memory.fail = !dropping; memory.dropWrite = dropping
    check(perform(&tested) == nil && tested.phase == .unknown && tested.originalRequest == onRaw &&
          !tested.canSet && savedRaw(memory) == onRaw, "명시 off 최초 저장 실패는 전송 0·원 on unknown 보존")
}

do {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let onRaw = tested.originalRequest!; _ = perform(&tested); let offRaw = tested.originalRequest!
    _ = tested.receive(reply(tested, "pending", intentState("on")), binding: binding, from: peerID)
    check(tested.phase == .pending && !tested.canSet && perform(&tested, desired: true) == nil,
          "off pending에서 control.manualIntent on이어도 추가 명령 0")
    _ = tested.receive(reply(tested, "unknown", intentState("on"), accepted: false), binding: binding, from: peerID)
    check(tested.phase == .unknown && tested.originalRequest == offRaw && tested.priorRequest == onRaw && !tested.canSet,
          "off unknown은 두 원문 유지·신규 명령 0")
    var restarted = ready(memory)
    check(restarted.originalRequest == offRaw && restarted.priorRequest == onRaw &&
          restarted.query(binding: binding, from: peerID, now: 200) == IPadSentryControl.packet(offRaw),
          "off unknown 재시작 후에도 현재 off만 exact 수동조회")
    _ = restarted.receive(reply(restarted, "applied", intentState("off", phase: .inactive, requested: false)), binding: binding, from: peerID)
    check(restarted.phase == .applied && restarted.originalRequest == offRaw && restarted.priorRequest == onRaw && restarted.canSet,
          "새 off applied 후 on/off 증거 보존·명시 다음 요청 허용")
    let oldOn = try! SentryControlRequest(rawRequest: restarted.priorRequest!)
    let superseded = SentryControlResponse(requestID: oldOn.requestID, accepted: true, operationState: .superseded,
        code: .superseded, state: try! JSONDecoder().decode(SentryState.self, from: json(intentState("off", phase: .inactive, requested: false))))
    check((try! SentryControlResponse.decodePayload(superseded.encodedPayload())).requestID == oldOn.requestID &&
          oldOn.rawRequest == onRaw, "off applied 후 보존 old on의 superseded 공통 응답 계약")
    check(restarted.receive(try! superseded.encodedPayload(), binding: binding, from: peerID) == nil &&
          restarted.phase == .unknown && restarted.originalRequest == offRaw && restarted.priorRequest == onRaw,
          "현재 off와 다른 late old-on 응답은 완료를 덮지 않고 두 원문 unknown 보존")
}

do {
    let memory = MemoryStore(); var tested = pendingOn(memory); let onRaw = tested.originalRequest!
    tested.bind(nil); tested.bind(otherID)
    observe(&tested, intentState("on", sessionID: nextSession, revisionID: nextSession), on: other)
    check(tested.phase == .unknown && !tested.canSet && tested.canQuery, "재접속은 current pending 수신 전 새 on/off 차단")
    check(tested.query(binding: binding, from: otherID, now: 130) == IPadSentryControl.packet(onRaw),
          "새 session에서 old session 포함 on 원문 exact query")
    _ = tested.receive(reply(tested, "pending", intentState("on", sessionID: nextSession, revisionID: nextSession)),
                       binding: binding, from: otherID)
    check(tested.phase == .pending && tested.canSet(desired: false) && !tested.canSet(desired: true),
          "current session 유효 pending-on 응답 후 새 명시 off 허용")
    let off = tested.perform(desired: false, binding: binding, from: otherID, now: 140)!
    let offRequest = try! SentryControlRequest(rawRequest: Data(off.dropFirst(14)))
    check(offRequest.sessionID == nextSession && offRequest.revision == nextSession &&
          offRequest.requestID != (try! SentryControlRequest(rawRequest: onRaw)).requestID && tested.priorRequest == onRaw,
          "재접속 off는 current session/revision/newID CAS·old on 원문 불변")
    _ = tested.receive(reply(tested, "applied", intentState("off", phase: .inactive, requested: false, sessionID: nextSession)),
                       binding: binding, from: otherID)
    check(tested.phase == .applied, "재접속 명시 off actual current reply 수용")
}

for change in ["host", "pin", "device", "boot", "authorization", "nil-trust", "old-session", "old-peer"] {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let onRaw = tested.originalRequest!; _ = perform(&tested); let offRaw = tested.originalRequest!
    var changedBinding: IPadSentryControl.Binding? = binding
    var report = intentState("on")
    if change == "old-session" {
        tested.bind(otherID); observe(&tested, intentState("on", sessionID: nextSession), on: other)
        _ = tested.receive(reply(tested, "applied", intentState("off", phase: .inactive, requested: false)), binding: binding, from: otherID)
    } else if change == "old-peer" {
        tested.bind(otherID); observe(&tested, intentState("on", sessionID: nextSession), on: other)
        _ = tested.receive(reply(tested, "applied", intentState("off", phase: .inactive, requested: false, sessionID: nextSession)), binding: binding, from: peerID)
    } else {
        switch change {
        case "host": changedBinding = .init(macID: "other", hostPin: binding.hostPin, deviceFingerprint: binding.deviceFingerprint)
        case "pin": changedBinding = .init(macID: binding.macID, hostPin: Data(repeating: 3, count: 32), deviceFingerprint: binding.deviceFingerprint)
        case "device": changedBinding = .init(macID: binding.macID, hostPin: binding.hostPin, deviceFingerprint: Data(repeating: 4, count: 32))
        case "boot": report["hostBootID"] = nextSession.uuidString
        case "authorization": var c = report["control"] as! [String: Any]; c["authorizationGeneration"] = nextAuth; report["control"] = c
        default: changedBinding = nil
        }
        observe(&tested, report, binding: changedBinding)
    }
    check(tested.phase == .unknown && tested.originalRequest == offRaw && tested.priorRequest == onRaw &&
          !tested.canSet, "두 원문 상태 late·권한 경계 \(change)")
}

let strictBase = Data((hostFixture["requestOnRaw"] as! String).utf8)
let strictString = String(decoding: strictBase, as: UTF8.self)
var malformedRequests: [Data] = [
    Data(("{\"desired\":true," + strictString.dropFirst()).utf8),
    Data(("{\"des\\u0069red\":true," + strictString.dropFirst()).utf8)
]
for mutation in ["extra", "missing", "null", "number", "version", "uppercase", "bad-uuid"] {
    var value = object(strictBase)
    switch mutation {
    case "extra": value["extra"] = true
    case "missing": value["desired"] = nil
    case "null": value["desired"] = NSNull()
    case "number": value["desired"] = 1
    case "version": value["version"] = 1
    case "uppercase": value["requestID"] = (value["requestID"] as! String).uppercased()
    default: value["revision"] = "invalid"
    }
    malformedRequests.append(json(value))
}
for (index, raw) in malformedRequests.enumerated() {
    check((try? SentryControlRequest(rawRequest: raw)) == nil && IPadSentryControl.packet(raw) == nil,
          "공통 strict request 중복·정확7필드·타입·UUID 거부 \(index)")
    let memory = MemoryStore()
    memory.data = json(["binding": object(try! JSONEncoder().encode(binding)), "rawRequest": raw.base64EncodedString()])
    let tested = ready(memory)
    check(tested.phase == .unknown && !tested.canSet && !tested.canQuery && memory.saves == 0,
          "손상 legacy raw를 새 ID로 마이그레이션하지 않음 \(index)")
}
for mutation in ["duplicate", "escaped-duplicate", "extra", "missing", "wrong-type", "duplicate-control", "extra-control", "unknown-capability", "rejected-success-code"] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested)
    let raw = tested.originalRequest!, valid = reply(tested, "applied", state())
    var payload = object(valid), bytes: Data
    switch mutation {
    case "duplicate": bytes = Data(("{\"accepted\":true," + String(decoding: valid, as: UTF8.self).dropFirst()).utf8)
    case "escaped-duplicate": bytes = Data(("{\"acc\\u0065pted\":true," + String(decoding: valid, as: UTF8.self).dropFirst()).utf8)
    case "duplicate-control": bytes = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"canSet\":true", with: "\"canSet\":true,\"canSet\":true").utf8)
    default:
        switch mutation {
        case "extra": payload["extra"] = true
        case "missing": payload["accepted"] = nil
        case "wrong-type": payload["accepted"] = 1
        case "rejected-success-code": payload["operationState"] = "rejected"
        default:
            var report = payload["state"] as! [String: Any], cap = report["control"] as! [String: Any]
            if mutation == "extra-control" { cap["future"] = true } else { cap["manualIntent"] = "future" }
            report["control"] = cap; payload["state"] = report
        }
        bytes = json(payload)
    }
    check((try? SentryControlResponse.decodePayload(bytes)) == nil &&
          tested.receive(bytes, binding: binding, from: peerID) == nil && tested.phase == .unknown && tested.originalRequest == raw,
          "공통 strict reply 중복·정확6필드·타입·cap·operation/code 거부 \(mutation)")
}

do {
    let typed = SentryControlCapability(authorizationGeneration: UUID(uuidString: auth)!, manualIntent: .on)
    let report = intentState("on")
    check(IPadSentryObservation.decodeCatalog(catalog(report))?.control == typed,
          "catalog adapter 유효 shared typed control 그대로 보존")
    var bad = report; var capability = bad["control"] as! [String: Any]; capability["manualIntent"] = "future"; bad["control"] = capability
    let decoded = IPadSentryObservation.decodeCatalog(catalog(bad))
    check(decoded?.control == nil && decoded?.phase == .pending && decoded?.requested == true,
          "unknown manualIntent는 v1 core 관찰만 남김")
    check(Wire.decode(WindowList.self, from: catalog(bad))?.videoEpoch?.isValid == true,
          "unknown capability에도 기존 영상 catalog 디코드 유지")
}
func savedLedger(_ memory: MemoryStore, prior: Bool = false) -> Bool? {
    guard let data = memory.data else { return nil }
    return object(data)[prior ? "priorLedgerAccepted" : "ledgerAccepted"] as? Bool
}

for scenario in ["saved-only", "before-send", "no-ack", "contentProcessed", "send-failed", "response-timeout"] {
    let memory = MemoryStore(), connection = NWConnection()
    let tested = StreamClient(store: memory.store), identity = ObjectIdentifier(connection)
    tested.connection = connection; tested.sentryObservation.bind(identity); tested.sentryControl.bind(identity)
    tested.observeIPadSentry(catalog: catalog(state()), from: connection)
    if scenario == "saved-only" {
        memory.data = json(["binding": object(try! JSONEncoder().encode(binding)), "rawRequest": legacyRaw.base64EncodedString()])
        tested.sentryControl = IPadSentryControl(store: memory.store)
        tested.sentryControl.bind(identity)
        tested.observeIPadSentry(catalog: catalog(state()), from: connection)
    } else if scenario == "before-send" {
        check(tested.sentryControl.perform(desired: true, binding: binding, from: identity, now: 100) != nil,
              "송신 직전 중단을 위한 저장·packet 반환")
        tested.sentryControl.checkTimeout(now: 110)
    } else {
        connection.acknowledgeSend = scenario != "no-ack"
        connection.failSend = scenario == "send-failed"
        tested.setIPadSentry(desired: true); pump()
        tested.sentryControl.checkTimeout(now: ProcessInfo.processInfo.systemUptime + 11)
    }
    let raw = tested.sentryControl.originalRequest!, sentCount = connection.sent.count
    check(savedLedger(memory) != true && !tested.sentryControl.canQuery &&
          tested.sentryControl.query(binding: binding, from: identity, now: 200) == nil && !tested.sentryControl.canSet,
          "원장 미접수 상태의 같은 session query·새 명령 차단 \(scenario)")
    tested.queryIPadSentry()
    check(connection.sent.count == sentCount && tested.sentryControl.originalRequest == raw &&
          tested.sentryControl.statusText.contains("연결을 다시 맺은 뒤"),
          "기존 query 진입점 자동 송신 0·재연결 안내 \(scenario)")
    var restarted = ready(memory)
    check(!restarted.canQuery && restarted.query(binding: binding, from: peerID, now: 200) == nil,
          "미접수 원문 재시작도 같은 session query 0 \(scenario)")
    restarted.bind(otherID); observe(&restarted, state(sessionID: nextSession), on: other)
    let savesBefore = memory.saves
    check(restarted.canQuery && restarted.query(binding: binding, from: otherID, now: 210) == IPadSentryControl.packet(raw) &&
          memory.saves == savesBefore, "같은 device/boot/auth 새 session에서만 exact old raw 조회 \(scenario)")
    _ = restarted.receive(reply(restarted, "unknown", state(sessionID: nextSession), accepted: false), binding: binding, from: otherID)
    check(restarted.phase == .unknown && savedLedger(memory) != true && restarted.originalRequest == raw &&
          !restarted.canSet && memory.saves == savesBefore, "미등록 old raw unknown/accepted=false는 최초 효과와 proof 0 \(scenario)")
}

for operation in ["pending", "applied", "failed", "target-unconfirmed"] {
    let memory = MemoryStore(); var tested = ready(memory)
    _ = perform(&tested, desired: true); let raw = tested.originalRequest!
    let phase: SentryState.Phase = operation == "applied" ? .userSessionProtected : operation == "pending" ? .pending : .blocked
    let code = operation == "failed" ? "SENTRY_CONTROL_FAILED" : operation == "target-unconfirmed" ? "SENTRY_TARGET_UNCONFIRMED" : nil
    let value = reply(tested, code == nil ? operation : "rejected", intentState("on", phase: phase), accepted: true, code: code)
    let before = memory.saves
    check(tested.receive(value, binding: binding, from: peerID) != nil && savedLedger(memory) == true &&
          memory.saves == before + 1 && tested.originalRequest == raw && tested.canQuery,
          "authenticated strict accepted=true만 접수 proof save/readback \(operation)")
    check((tested.phase == .applied) == (operation == "applied"), "접수 확인은 완료 상태와 별개 \(operation)")
    var restarted = ready(memory)
    check(restarted.phase == .unknown && savedLedger(memory) == true && restarted.canQuery &&
          restarted.query(binding: binding, from: peerID, now: 200) == IPadSentryControl.packet(raw),
          "접수 true는 재시작 후에도 같은 session exact query 허용 \(operation)")
    let saves = memory.saves
    _ = restarted.receive(reply(restarted, "unknown", intentState("on"), accepted: false), binding: binding, from: peerID)
    check(savedLedger(memory) == true && memory.saves == saves && restarted.phase == .unknown && restarted.canQuery,
          "accepted=false가 기존 true proof를 내리지 않음 \(operation)")
}

for dropping in [false, true] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested, desired: true)
    let raw = tested.originalRequest!
    memory.fail = !dropping; memory.dropWrite = dropping
    check(tested.receive(reply(tested, "pending", intentState("on")), binding: binding, from: peerID) == nil &&
          tested.phase == .unknown && !tested.canQuery && tested.query(binding: binding, from: peerID, now: 200) == nil &&
          !tested.canSet && tested.originalRequest == raw && savedLedger(memory) == false,
          "접수 proof 저장·readback 실패는 availability 전에 unknown·같은 session query 0")
    var restarted = ready(memory)
    check(!restarted.canQuery && restarted.originalRequest == raw, "proof 저장 실패 후 재시작도 같은 session query 0")
    restarted.bind(otherID); observe(&restarted, intentState("on", sessionID: nextSession), on: other)
    check(restarted.query(binding: binding, from: otherID, now: 210) == IPadSentryControl.packet(raw),
          "proof 저장 실패라도 새 session은 최초 효과 없는 exact old raw 조회")
}

do {
    let memory = MemoryStore(); var tested = pendingOn(memory); let onRaw = tested.originalRequest!
    check(savedLedger(memory) == true, "pending-on은 접수 확인 true")
    _ = perform(&tested); let offRaw = tested.originalRequest!
    check(savedLedger(memory) == false && savedLedger(memory, prior: true) == true && tested.priorRequest == onRaw,
          "새 off의 false와 prior on의 true를 원문별로 저장")
    _ = tested.receive(reply(tested, "rejected", intentState("on"), accepted: false, code: "SENTRY_BUSY"), binding: binding, from: peerID)
    check(tested.originalRequest == onRaw && tested.priorRequest == offRaw && savedLedger(memory) == true &&
          savedLedger(memory, prior: true) == false && tested.canQuery && !tested.canSet,
          "BUSY 복원은 on true·off false를 raw와 정확 교환")
    var restarted = ready(memory)
    check(restarted.originalRequest == onRaw && restarted.priorRequest == offRaw && savedLedger(memory) == true &&
          savedLedger(memory, prior: true) == false && restarted.query(binding: binding, from: peerID, now: 200) == IPadSentryControl.packet(onRaw),
          "BUSY 복원 후 재시작도 on 접수 proof만 같은 session query에 사용")
}

for change in ["host", "pin", "device", "boot", "authorization", "nil-trust", "old-peer", "old-session", "malformed"] {
    let memory = MemoryStore(); var tested = ready(memory); _ = perform(&tested, desired: true)
    let raw = tested.originalRequest!; var report = intentState("on")
    var current: IPadSentryControl.Binding? = binding
    switch change {
    case "host": current = .init(macID: "different", hostPin: binding.hostPin, deviceFingerprint: binding.deviceFingerprint)
    case "pin": current = .init(macID: binding.macID, hostPin: Data(repeating: 6, count: 32), deviceFingerprint: binding.deviceFingerprint)
    case "device": current = .init(macID: binding.macID, hostPin: binding.hostPin, deviceFingerprint: Data(repeating: 6, count: 32))
    case "boot": report["hostBootID"] = nextSession.uuidString
    case "authorization": var cap = report["control"] as! [String: Any]; cap["authorizationGeneration"] = nextAuth; report["control"] = cap
    case "nil-trust": current = nil
    default: break
    }
    let saves = memory.saves
    let bytes = change == "malformed" ? Data("{".utf8) : reply(tested, "pending", report)
    if change == "old-peer" || change == "old-session" {
        tested.bind(otherID); observe(&tested, intentState("on", sessionID: nextSession), on: other)
        _ = tested.receive(bytes, binding: binding, from: change == "old-peer" ? peerID : otherID)
    } else {
        _ = tested.receive(bytes, binding: current, from: peerID)
    }
    check(savedLedger(memory) == false && memory.saves == saves && tested.originalRequest == raw && !tested.canSet,
          "다른 trust·scope·손상 응답으로 접수 proof 승격 0 \(change)")
}

for change in ["host", "pin", "device", "boot", "authorization", "nil-trust"] {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    var report = intentState("on"), current: IPadSentryControl.Binding? = binding
    switch change {
    case "host": current = .init(macID: "different", hostPin: binding.hostPin, deviceFingerprint: binding.deviceFingerprint)
    case "pin": current = .init(macID: binding.macID, hostPin: Data(repeating: 6, count: 32), deviceFingerprint: binding.deviceFingerprint)
    case "device": current = .init(macID: binding.macID, hostPin: binding.hostPin, deviceFingerprint: Data(repeating: 6, count: 32))
    case "boot": report["hostBootID"] = nextSession.uuidString
    case "authorization": var cap = report["control"] as! [String: Any]; cap["authorizationGeneration"] = nextAuth; report["control"] = cap
    default: current = nil
    }
    observe(&tested, report, binding: current)
    check(savedLedger(memory) == true && !tested.canQuery &&
          tested.query(binding: current, from: peerID, now: 200) == nil && !tested.canSet,
          "저장된 true도 다른 binding·boot·auth의 조회 권한으로 사용하지 않음 \(change)")
}
do {
    let memory = MemoryStore(); var tested = pendingOn(memory)
    let raw = tested.originalRequest!, saves = memory.saves
    check(tested.query(binding: binding, from: peerID, now: 200) == IPadSentryControl.packet(raw),
          "접수 확인된 old CAS는 같은 session에서 exact 원문 조회 가능")
    _ = tested.receive(reply(tested, "unknown", intentState("off", phase: .inactive, requested: false,
                          revisionID: nextSession), accepted: false), binding: binding, from: peerID)
    check(tested.phase == .unknown && savedLedger(memory) == true && memory.saves == saves &&
          tested.originalRequest == raw && tested.canQuery && !tested.canSet && perform(&tested) == nil,
          "Host 원장 eviction unknown은 true eligibility 유지·완료/새 실행/원문 CAS 수정 0")
}
print("소비자 회귀 \(checks)/\(checks) 통과")
