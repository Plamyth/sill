import Foundation

typealias Model = IPadConfiguredCraftAction
let host = String(repeating: "a", count: 64)
let device = String(repeating: "b", count: 64)
let hash = String(repeating: "c", count: 64)
let otherHash = String(repeating: "d", count: 64)
let epoch: Int64 = 1_794_000_000_123
var checks = 0

func check(_ condition: Bool, _ name: String) {
    guard condition else { fatalError("FAIL: \(name)") }
    checks += 1
}

func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL: \(name)") }
    catch { checks += 1 }
}

func bytes(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func response(_ request: Model.Request, outcome: String = "invoked", invoked: Bool = true,
              binding: Any = hash) -> [String: Any] {
    ["outcome": outcome, "operationId": request.operationId.uuidString,
     "deviceId": request.deviceId, "bindingSha256": binding,
     "invoked": invoked, "effectConfirmed": false]
}

final class Clock { var now: TimeInterval = 100 }

final class Fixture {
    let clock = Clock()
    let context: Model.Context
    let catalog: Model.Catalog
    var model: Model
    init(ready: Bool = true) throws {
        context = try .init(connection: UUID(), hostID: host, deviceID: device)
        catalog = try .init(context: context, profileID: UUID(), assignmentSha256: hash)
        let clock = self.clock
        model = Model(clock: { clock.now })
        model.bind(context)
        if ready { activate() }
    }
    func activate(input: Bool = true, output: Bool = true) {
        model.observe(from: context, authenticated: true, endpointSupported: true,
                      catalog: catalog, inputReady: input, outputReady: output)
    }
    func begin(action: UUID = UUID(), duration: Int = 500, issued: Int64 = epoch) -> Model.Request? {
        model.begin(from: context, catalog: catalog, userActionID: action,
                    heldMilliseconds: duration, issuedAt: issued)
    }
}

let normal = try Fixture()
let action = UUID()
let request = normal.begin(action: action)!
let encoded = try JSONEncoder().encode(request)
let requestObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
let expectedKeys: Set<String> = ["schemaVersion", "operation", "operationId", "deviceId", "inputID", "trigger",
                               "expectedProfileId", "expectedAssignmentSha256", "issuedAt"]
// Independent agreed wire fixture: no timestamp alias or client session claim.
let agreedWire = Data(#"{"schemaVersion":1,"operation":"invoke-configured-craft-action","operationId":"11111111-2222-3333-4444-555555555555","deviceId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","inputID":"speed.button.stop-play","trigger":"longPress","expectedProfileId":"66666666-7777-8888-9999-000000000000","expectedAssignmentSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","issuedAt":1794000000123}"#.utf8)
let agreed = try JSONDecoder().decode(Model.Request.self, from: agreedWire)
let agreedObject = try JSONSerialization.jsonObject(with: agreedWire) as! [String: Any]
var normalized = requestObject
normalized["operationId"] = agreed.operationId.uuidString
normalized["expectedProfileId"] = agreed.expectedProfileId.uuidString
check(NSDictionary(dictionary: normalized).isEqual(to: agreedObject), "독립 확정 schema fixture와 실제 요청 9필드 직접 대조")
check(Set(requestObject.keys) == expectedKeys, "요청은 확정된 9필드만 포함")
check(requestObject["operation"] as? String == "invoke-configured-craft-action", "operation을 직접 포함")
check(requestObject["schemaVersion"] as? Int == 1 && requestObject["inputID"] as? String == "speed.button.stop-play"
      && requestObject["trigger"] as? String == "longPress", "확정 schema와 동작")
check(requestObject["issuedAt"] as? Int64 == epoch, "epoch 밀리초 정수 number")
check(requestObject["expectedProfileId"] as? String == normal.catalog.profileID.uuidString
      && requestObject["expectedAssignmentSha256"] as? String == hash, "catalog 식별값만 그대로 사용")
check(try JSONDecoder().decode(Model.Request.self, from: encoded) == request, "실제 Codable 왕복")
check(normal.begin() == nil && normal.model.pending?.request == request, "pending 중 새 operation 생성 없음")
check(try normal.model.receive(bytes(response(request)), from: normal.context), "invoked 응답 소비")
check(normal.model.resolution?.outcome == .invoked && normal.model.resolution?.invoked == true
      && normal.model.resolution?.effectConfirmed == false, "executor 전달을 통화 성공으로 해석하지 않음")
check(normal.begin(action: action) == nil, "같은 명시 gesture를 두 번 소비하지 않음")
let second = normal.begin()!
check(second.operationId != request.operationId, "known 이후 별도 명시 동작만 새 operation 생성")

for key in expectedKeys {
    var wire = requestObject; wire.removeValue(forKey: key)
    rejects("request 필수 key: \(key)") { _ = try JSONDecoder().decode(Model.Request.self, from: bytes(wire)) }
}
for key in ["issuedAtUTC", "deviceSessionId", "deviceSessionID", "action", "keyCode", "modifiers", "extra"] {
    var wire = requestObject; wire[key] = "forbidden"
    rejects("request 추가 key: \(key)") { _ = try JSONDecoder().decode(Model.Request.self, from: bytes(wire)) }
}
let badRequestValues: [(String, Any)] = [
    ("schemaVersion", 2), ("schemaVersion", true), ("operation", "query"), ("operationId", "bad"),
    ("deviceId", host.uppercased()), ("deviceId", device + "\n"), ("deviceId", "é"),
    ("inputID", "other"), ("trigger", "press"), ("expectedProfileId", "not-a-uuid"),
    ("expectedAssignmentSha256", hash.uppercased()), ("expectedAssignmentSha256", String(hash.dropLast())),
    ("issuedAt", "1794000000123"), ("issuedAt", 1794000000123.5), ("issuedAt", true),
    ("issuedAt", -1), ("issuedAt", 9_007_199_254_740_992 as Int64), ("issuedAt", NSNull())
]
for (key, value) in badRequestValues {
    var wire = requestObject; wire[key] = value
    rejects("request 잘못된 값: \(key)=\(value)") { _ = try JSONDecoder().decode(Model.Request.self, from: bytes(wire)) }
}

let goodResponse = response(request)
for key in goodResponse.keys {
    var wire = goodResponse; wire.removeValue(forKey: key)
    rejects("response 필수 key: \(key)") { _ = try JSONDecoder().decode(Model.Response.self, from: bytes(wire)) }
}
let badResponseValues: [(String, Any)] = [
    ("outcome", "started"), ("outcome", NSNull()), ("operationId", "bad"), ("deviceId", "bad"),
    ("deviceId", device.uppercased()), ("bindingSha256", hash.uppercased()), ("bindingSha256", hash + "\n"),
    ("bindingSha256", 12), ("bindingSha256", NSNull()), ("invoked", false), ("invoked", 1),
    ("effectConfirmed", true), ("effectConfirmed", 0), ("reason", ""), ("reason", " \n\t"),
    ("reason", String(repeating: "a", count: 257)), ("reason", String(repeating: "가", count: 86)),
    ("reason", NSNull()), ("reason", 1)
]
for (key, value) in badResponseValues {
    var wire = goodResponse; wire[key] = value
    rejects("response 잘못된 값: \(key)=\(value)") { _ = try JSONDecoder().decode(Model.Response.self, from: bytes(wire)) }
}
for key in ["deviceSessionId", "deviceSessionID", "operation", "profileId", "extra"] {
    var wire = goodResponse; wire[key] = "forbidden"
    rejects("response 추가 key: \(key)") { _ = try JSONDecoder().decode(Model.Response.self, from: bytes(wire)) }
}
var bounded = goodResponse; bounded["reason"] = String(repeating: "a", count: 256)
check(try JSONDecoder().decode(Model.Response.self, from: bytes(bounded)).reason?.utf8.count == 256,
      "bounded reason 경계")
rejects("rejected는 invoked false 필수") {
    _ = try JSONDecoder().decode(Model.Response.self, from: bytes(response(request, outcome: "rejected")))
}

let unsupported = try Fixture(ready: false)
check(!unsupported.model.supported && unsupported.begin() == nil, "기본 unsupported")
unsupported.model.observe(from: unsupported.context, authenticated: true, catalog: unsupported.catalog,
                          inputReady: true, outputReady: true)
check(!unsupported.model.supported && unsupported.begin() == nil, "endpoint 생략 시 unsupported")
unsupported.model.observe(from: unsupported.context, authenticated: false, endpointSupported: true,
                          catalog: unsupported.catalog, inputReady: true, outputReady: true)
check(unsupported.begin() == nil, "미인증 거절")
unsupported.model.observe(from: unsupported.context, authenticated: true, endpointSupported: true,
                          catalog: nil, inputReady: true, outputReady: true)
check(unsupported.begin() == nil, "catalog 없음 거절")
unsupported.activate()
let shortAction = UUID()
check(unsupported.begin(action: shortAction, duration: 499) == nil && unsupported.model.state == .idle, "499ms 거절")
check(unsupported.begin(action: shortAction, duration: 500) != nil, "500ms 명시 동작은 한 번 소비")
for (input, output) in [(false, true), (true, false), (false, false)] {
    let f = try Fixture(); f.activate(input: input, output: output)
    check(f.begin() == nil && f.model.pending == nil, "실제 입출력 unready 거절 \(input)/\(output)")
}
for invalid in [-1, 9_007_199_254_740_992 as Int64] {
    let f = try Fixture()
    check(f.begin(issued: invalid) == nil, "잘못된 epoch에서 operation 생성 0")
}
for invalid in ([-1, .nan, .infinity, .greatestFiniteMagnitude] as [TimeInterval]) {
    let f = try Fixture(); f.clock.now = invalid
    check(f.begin() == nil, "잘못된 단조 시계에서 생성 0")
}

for invalid in ["", "a", host.uppercased(), host + "\n", String(repeating: "ａ", count: 64)] {
    rejects("host 64hex 검증") { _ = try Model.Context(connection: UUID(), hostID: invalid, deviceID: device) }
    rejects("device 64hex 검증") { _ = try Model.Context(connection: UUID(), hostID: host, deviceID: invalid) }
}
rejects("catalog hash 검증") {
    _ = try Model.Catalog(context: normal.context, profileID: UUID(), assignmentSha256: "bad")
}
rejects("catalog schema 검증") {
    _ = try Model.Catalog(context: normal.context, schemaVersion: 2, profileID: UUID(), assignmentSha256: hash)
}
rejects("catalog input 검증") {
    _ = try Model.Catalog(context: normal.context, inputID: "other", profileID: UUID(), assignmentSha256: hash)
}
rejects("catalog trigger 검증") {
    _ = try Model.Catalog(context: normal.context, trigger: "press", profileID: UUID(), assignmentSha256: hash)
}

let stale = try Fixture()
for catalog in [try Model.Catalog(context: stale.context, profileID: UUID(), assignmentSha256: hash),
                try Model.Catalog(context: stale.context, profileID: stale.catalog.profileID, assignmentSha256: otherHash)] {
    check(stale.model.begin(from: stale.context, catalog: catalog, userActionID: UUID(), heldMilliseconds: 500,
                            issuedAt: epoch) == nil, "stale profile/hash의 gesture 거절")
}
let alienContexts = [
    try Model.Context(connection: UUID(), hostID: host, deviceID: device),
    try Model.Context(connection: stale.context.connection, hostID: otherHash, deviceID: device),
    try Model.Context(connection: stale.context.connection, hostID: host, deviceID: otherHash)
]
for context in alienContexts {
    check(stale.model.begin(from: context, catalog: stale.catalog, userActionID: UUID(), heldMilliseconds: 500,
                            issuedAt: epoch) == nil, "다른 connection/host/device의 begin 거절")
    check(!stale.model.observe(from: context, authenticated: true, endpointSupported: true,
                              catalog: stale.catalog, inputReady: true, outputReady: true), "이전 context 관측 거절")
}
let matched = stale.begin()!
let waiting = stale.model.state
for (key, value) in [("operationId", UUID().uuidString), ("deviceId", otherHash), ("bindingSha256", otherHash)] {
    var wire = response(matched); wire[key] = value
    check(try !stale.model.receive(bytes(wire), from: stale.context) && stale.model.state == waiting,
          "다른 operation/device/hash를 소비하지 않음")
}
for context in alienContexts {
    check(try !stale.model.receive(bytes(response(matched)), from: context) && stale.model.state == waiting,
          "다른 session context 응답 거절")
}
var badEffect = response(matched); badEffect["effectConfirmed"] = true
rejects("true effect를 모델 진입점에서 거절") { _ = try stale.model.receive(bytes(badEffect), from: stale.context) }
var extra = response(matched); extra["deviceSessionId"] = UUID().uuidString
rejects("session 권한 주장을 모델 진입점에서 거절") { _ = try stale.model.receive(bytes(extra), from: stale.context) }
check(stale.model.state == waiting && stale.begin() == nil, "잘못된 wire는 pending을 해제하지 않음")
check(try stale.model.receive(bytes(response(matched)), from: stale.context), "잘못된 응답 이후 올바른 ACK 소비")

for binding in ([NSNull(), otherHash] as [Any]) {
    let f = try Fixture(); let req = f.begin()!
    check(try f.model.receive(bytes(response(req, outcome: "rejected", invoked: false, binding: binding)), from: f.context),
          "비교 전 null과 실제 다른 hash의 rejected 소비")
    check(f.model.resolution?.outcome == .rejected && f.model.resolution?.invoked == false,
          "rejected 결과 사실 보존")
    let next = f.begin()
    check(f.model.resolution == nil && next != nil && next!.operationId != req.operationId,
          "known rejected 이후 새 명시 동작")
}
for invoked in [false, true] {
    for binding in ([NSNull(), hash] as [Any]) {
        let f = try Fixture(); let req = f.begin()!
        check(try f.model.receive(bytes(response(req, outcome: "unknown", invoked: invoked, binding: binding)), from: f.context),
              "unknown + invoked \(invoked) / null과 일치 hash 소비")
        let retained = f.model.state
        check(f.model.resolution?.outcome == .unknown && f.model.resolution?.invoked == invoked
              && f.model.resolution?.effectConfirmed == false && f.begin() == nil, "unknown 사실을 보존하고 재호출 0")
        f.model.disconnected(); f.model.bind(f.context); f.activate()
        check(f.model.state == retained && f.begin() == nil, "재연결로 unknown을 초기화하지 않음")
        check(try !f.model.receive(bytes(response(req)), from: f.context), "unknown 이후 늦은 invoked로 성공화하지 않음")
    }
}
let wrongUnknown = try Fixture(); let wrongUnknownRequest = wrongUnknown.begin()!
check(try !wrongUnknown.model.receive(bytes(response(wrongUnknownRequest, outcome: "unknown", invoked: true,
                                                   binding: otherHash)), from: wrongUnknown.context), "unknown의 nonnull hash도 대조")

let timed = try Fixture(); let timedRequest = timed.begin()!
check(!timed.model.timeout(operationId: timedRequest.operationId), "너무 이른 timeout 무효")
timed.clock.now = 110
check(!timed.model.timeout(operationId: UUID()), "다른 operation timeout 무효")
check(timed.model.timeout(operationId: timedRequest.operationId), "10초 경계에서 unknown 확정")
check(timed.model.resolution?.localUnknownReason == .timeout && timed.model.resolution?.invoked == nil
      && timed.model.resolution?.effectConfirmed == false, "local timeout을 executor 미호출로 합성하지 않음")
check(!timed.model.timeout(operationId: timedRequest.operationId) && timed.begin() == nil, "timeout 이후 재처리와 새 operation 0")
check(try !timed.model.receive(bytes(response(timedRequest)), from: timed.context), "timeout 이후 늦은 응답 거절")
timed.model.bind(timed.context); timed.activate()
check(timed.begin() == nil && timed.model.resolution?.pending.request == timedRequest, "bind로 timeout을 없애지 않음")
let implicitTimeout = try Fixture(); let implicitRequest = implicitTimeout.begin()!
implicitTimeout.clock.now = 110
check(try !implicitTimeout.model.receive(bytes(response(implicitRequest)), from: implicitTimeout.context)
      && implicitTimeout.model.resolution?.outcome == .unknown, "timeout callback 전 만료된 ACK도 unknown")
for invalid in ([99, .nan, .infinity] as [TimeInterval]) {
    let f = try Fixture(); let req = f.begin()!; f.clock.now = invalid
    check(f.model.timeout(operationId: req.operationId) && f.model.resolution?.localUnknownReason == .invalidClock
          && f.begin() == nil, "시계 이상도 unknown 유지")
}

for sameConnection in [false, true] {
    let f = try Fixture(); let req = f.begin()!
    let next = try Model.Context(connection: sameConnection ? f.context.connection : UUID(), hostID: host, deviceID: device)
    f.model.bind(next)
    check(!f.model.supported && f.model.resolution?.pending.request == req, "bind는 capability 폐기와 이전 operation 보존")
    let nextCatalog = try Model.Catalog(context: next, profileID: f.catalog.profileID, assignmentSha256: hash)
    f.model.observe(from: next, authenticated: true, endpointSupported: true, catalog: nextCatalog,
                    inputReady: true, outputReady: true)
    check(try !f.model.receive(bytes(response(req)), from: f.context), "bind 이후 이전 응답 거절")
    check(try !f.model.receive(bytes(response(req)), from: next), "이전 응답에 새 context를 붙여도 거절")
    check(f.model.begin(from: next, catalog: nextCatalog, userActionID: UUID(), heldMilliseconds: 500,
                        issuedAt: epoch) == nil, "새 connection도 불명확한 operation을 재전송하지 않음")
}
let disconnected = try Fixture(); let disconnectedRequest = disconnected.begin()!
disconnected.model.disconnected()
check(disconnected.model.context == nil && !disconnected.model.supported
      && disconnected.model.resolution?.pending.request == disconnectedRequest, "disconnect는 전송 없이 unknown 보존")
check(try !disconnected.model.receive(bytes(response(disconnectedRequest)), from: disconnected.context), "연결 해제 이후 ACK 거절")

let changed = try Fixture(); let changedRequest = changed.begin()!
let changedCatalog = try Model.Catalog(context: changed.context, profileID: changed.catalog.profileID, assignmentSha256: otherHash)
changed.model.observe(from: changed.context, authenticated: true, endpointSupported: true, catalog: changedCatalog,
                      inputReady: true, outputReady: true)
check(changed.model.resolution?.localUnknownReason == .catalogChanged && changed.begin() == nil,
      "pending 중 binding 변경 시 unknown 유지")
check(try !changed.model.receive(bytes(response(changedRequest)), from: changed.context), "이전 binding 결과 거절")

for authenticationLost in [false, true] {
    let f = try Fixture(); let req = f.begin()!
    f.model.observe(from: f.context, authenticated: !authenticationLost, endpointSupported: authenticationLost,
                    catalog: f.catalog, inputReady: true, outputReady: true)
    check(!f.model.supported && f.model.resolution?.localUnknownReason == .capabilityWithdrawn, "인증 또는 capability 폐기")
    f.activate()
    check(f.begin() == nil && f.model.resolution?.pending.request == req, "인증 복귀는 재호출하지 않음")
}
let wrongCatalog = try Fixture()
let foreignCatalog = try Model.Catalog(context: alienContexts[0], profileID: UUID(), assignmentSha256: hash)
check(!wrongCatalog.model.observe(from: wrongCatalog.context, authenticated: true, endpointSupported: true,
                                  catalog: foreignCatalog, inputReady: true, outputReady: true)
      && wrongCatalog.begin() == nil, "다른 session의 catalog 거절")

let mediaLost = try Fixture(); let mediaRequest = mediaLost.begin()!
mediaLost.activate(input: false)
check(try mediaLost.model.receive(bytes(response(mediaRequest)), from: mediaLost.context)
      && mediaLost.model.resolution?.effectConfirmed == false && mediaLost.begin() == nil,
      "media 미준비 시에도 executor ACK 사실만 보존")
let known = try Fixture(); let knownRequest = known.begin()!
_ = try known.model.receive(bytes(response(knownRequest)), from: known.context)
known.model.disconnected(); known.model.bind(known.context)
check(!known.model.supported && known.begin() == nil, "known 이후에도 bind만으로 capability가 복귀하지 않음")
known.activate()
let knownNext = known.begin()
check(knownNext != nil && knownNext!.operationId != knownRequest.operationId,
      "known 이후 새 catalog와 별도 명시 동작으로 재개 가능")

print("PASS: \(checks) Codable·소비 상태 검사. 통화/UI/기기/네트워크 효과는 검사 범위 밖입니다.")
