import Foundation
import StreamProtocol

typealias P = IPadEnrollmentProtocol
typealias J = IPadEnrollmentJSON
var assertions = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    guard try condition() else { fatalError(message) }
}
func reject(_ message: String, _ action: () throws -> Void) {
    assertions += 1
    do { try action(); fatalError(message) } catch {}
}
func settle(file: StaticString = #file, line: UInt = #line, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    precondition(predicate(), "메모리 비동기 작업 마감", file: file, line: line)
}
func object(_ value: J) -> [String: J] { if case .object(let fields) = value { return fields }; fatalError("fixture 객체") }
func data(_ value: J) -> Data { try! value.bytes() }
func text(_ value: J) -> String { try! value.text() }
func changed(_ value: J, _ key: String, _ new: J) -> J { var fields = object(value); fields[key] = new; return .object(fields) }
func readFixture(_ name: String) throws -> J {
    try J.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)), limit: 32_768)
}
let golden = try readFixture("device-enrollment-golden-v2.json")
let readbackGolden = try readFixture("device-enrollment-readback-golden.json")
try check(object(golden)["synthetic"] == .bool(true) && object(readbackGolden)["synthetic"] == .bool(true), "공개 합성 자료만 사용")

final class Memory {
    let fixture: [String: J]
    let binding: P.Binding
    let challenge: P.Challenge
    let receipt: P.Receipt
    let enrollBody: Data
    let readbackMessage: Data
    var raw: Data?
    var now: Int64 = 1_800_000_000_000
    var current = true
    var casFails = false
    var loadFails = false
    var failOnWrite: Int?
    var readbackCorrupts = false
    var writes = 0
    var receiptCalls = 0
    var signCalls = 0
    var requests: [(IPadDeviceEnrollment.Route, Data)] = []
    var parked: ((Result<IPadDeviceEnrollment.HTTPReply, Error>) -> Void)?
    var holdChallenge = false
    var parkRoute: IPadDeviceEnrollment.Route?
    var loseEnroll = false
    var responseOverride: (Int, J)?
    var postHandler: ((IPadDeviceEnrollment.Route, Data) -> Result<IPadDeviceEnrollment.HTTPReply, Error>)?
    var receiptHandler: ((P.Challenge) throws -> Data)?
    var onWrite: ((Data) -> Void)?
    var readbackChallengeOverride: J?
    var token = String(repeating: "a", count: 64)
    let refusals = IPadDeviceEnrollment.Refusals()
    init(_ fixture: J) throws {
        self.fixture = object(fixture)
        let enroll = object(self.fixture["enrollRequest"]!)
        let envelope = object(enroll["ownerReceipt"]!)
        let payload = try J.parse(P.decode(text(envelope["payload"]!), maximum: 4096))
        let pin = P.hash(try P.decode(text(envelope["publicSPKI"]!), maximum: 128))
        binding = try P.Binding(macID: text(object(payload)["macID"]!), hostPin: pin,
            deviceSPKI: P.decode(text(enroll["devicePublicKey"]!), maximum: 128))
        challenge = try P.Challenge(data(self.fixture["challengeResponse"]!), binding: binding, now: now)
        receipt = try P.Receipt(data(enroll["ownerReceipt"]!), challenge: challenge, binding: binding, now: now)
        enrollBody = data(self.fixture["enrollRequest"]!)
        readbackMessage = try P.decode(text(self.fixture["readbackSigningMessageBase64url"]!), maximum: 4096)
    }
    func response(_ body: J) -> Result<IPadDeviceEnrollment.HTTPReply, Error> { response(200, body) }
    func response(_ status: Int, _ body: J) -> Result<IPadDeviceEnrollment.HTTPReply, Error> {
        .success(.init(status: status, contentType: "application/json; charset=utf-8", body: data(body)))
    }
    var credential: J { .object(["schema": .string("ccr.device-credential/v1"), "deviceId": .string(binding.deviceID),
        "credentialId": .string("synthetic-own-device"), "token": .string(token),
        "expiresAt": .integer(1_800_086_400_000), "origin": .string(P.origin)]) }
    func engine() -> IPadDeviceEnrollment {
        IPadDeviceEnrollment(binding: binding, io: .init(load: { [self] in
            if loadFails { throw IPadEnrollmentFailure.storage }; return raw
        }, compareAndSwap: { [self] expected, next in
            guard !casFails, failOnWrite != writes + 1, raw == expected else { throw IPadEnrollmentFailure.storage }
            writes += 1; raw = readbackCorrupts ? Data("corrupt".utf8) : next
            onWrite?(next)
        }, post: { [self] route, body, done in
            requests.append((route, body))
            if route == .challenge && holdChallenge || route == parkRoute { parked = done; return {} }
            if let override = responseOverride { done(response(override.0, override.1)); return {} }
            switch route {
            case .challenge: done(response(fixture["challengeResponse"]!))
            case .enroll:
                if loseEnroll { done(.failure(IPadEnrollmentFailure.unavailable)) }
                else { done(response(credential)) }
            case .readbackChallenge: done(response(readbackChallengeOverride ?? fixture["readbackChallenge"]!))
            case .readback: done(response(credential))
            }
            return {}
        }, ownerReceipt: { [self] _, done in
            receiptCalls += 1; done(.success(data(object(fixture["enrollRequest"]!)["ownerReceipt"]!))); return {}
        }, sign: { [self] message in
            signCalls += 1
            if message == receipt.proofMessage { return try P.decode(text(object(fixture["enrollRequest"]!)["signature"]!), maximum: 72) }
            guard message == readbackMessage else { throw IPadEnrollmentFailure.invalid }
            return try P.decode(text(object(fixture["readbackRequest"]!)["signature"]!), maximum: 72)
        }, current: { [self] in current }, now: { [self] in now }), refusals: refusals)
    }
    func ensure(_ engine: IPadDeviceEnrollment) -> Result<P.Credential, Error> {
        var result: Result<P.Credential, Error>?
        engine.ensure { result = $0 }; settle { result != nil }; return result!
    }
}

let gold = object(golden)
let host = object(gold["host"]!), device = object(gold["device"]!)
let goldBinding = try P.Binding(macID: "XZHRCCWCM0S180VN", hostPin: P.decode(text(host["fingerprintBase64url"]!), maximum: 32),
    deviceSPKI: P.decode(text(device["publicSPKI"]!), maximum: 128))
let goldChallenge = try P.Challenge(data(gold["challengeResponse"]!), binding: goldBinding, now: 1_800_000_000_000)
let goldReceipt = try P.Receipt(data(gold["ownerReceipt"]!), challenge: goldChallenge, binding: goldBinding, now: 1_800_000_000_000)
try check(goldReceipt.proofMessage == P.decode(text(device["proofMessage"]!), maximum: 4096), "Android golden 기기 증명문")
try check(P.hex(P.hash(goldReceipt.proofMessage)) == text(device["proofMessageSha256"]!), "golden proof hash")
let enrollmentSignature = try P.decode(text(object(gold["enrollRequest"]!)["signature"]!), maximum: 72)
_ = try P.enroll(goldReceipt, challenge: goldChallenge, binding: goldBinding, signature: enrollmentSignature)
try check(try P.requestDigest(data(object(readbackGolden)["enrollRequest"]!)) == "27dc24fd08d264847e1c5efa8a2d71ed9b81057953417b162aa61e745010b776", "원문 정규화 digest")
let m = try Memory(readbackGolden)
let rb = try P.Readback(data(m.fixture["readbackChallenge"]!), challenge: m.challenge,
    digest: P.requestDigest(m.enrollBody), binding: m.binding, now: m.now + 31_000)
try check(rb.message == m.readbackMessage, "fresh readback golden 서명문")
try check(try P.publicKey(m.binding.deviceSPKI).isValidSignature(P.signature(P.decode(text(object(m.fixture["readbackRequest"]!)["signature"]!), maximum: 72)), for: rb.message), "readback golden 기기 서명")
reject("변조 readback 서명문") { guard try P.publicKey(m.binding.deviceSPKI).isValidSignature(P.signature(P.decode(text(object(m.fixture["readbackRequest"]!)["signature"]!), maximum: 72)), for: rb.message + Data([0])) else { throw IPadEnrollmentFailure.invalid } }

for invalid in ["true", "1.0", "1e0", "\"1800000030000\"", "null", "9007199254740992", "-1"] {
    let raw = String(decoding: data(gold["challengeResponse"]!), as: UTF8.self).replacingOccurrences(of: "1800000030000", with: invalid)
    reject("엄격 밀리초 \(invalid)") { _ = try P.Challenge(Data(raw.utf8), binding: goldBinding, now: 1_800_000_000_000) }
}
for raw in [#"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#, #"{"x":"\uD800"}"#, #"{"x":01}"#, #"{"x":1}false"#, #"{"x":[] ,}"#] {
    reject("중복·손상 JSON") { _ = try J.parse(Data(raw.utf8)) }
}
reject("추가 challenge 필드") { _ = try P.Challenge(data(changed(gold["challengeResponse"]!, "extra", .null)), binding: goldBinding, now: 1_800_000_000_000) }
for time: Int64 in [1_799_999_998_999, 1_800_000_010_000, 1_800_000_031_000] {
    reject("future/expired receipt") { _ = try P.Receipt(data(gold["ownerReceipt"]!), challenge: goldChallenge, binding: goldBinding, now: time) }
}
for key in ["payload", "signature", "publicSPKI"] {
    var fields = object(gold["ownerReceipt"]!)
    var bytes = try P.decode(text(fields[key]!), maximum: 4096); bytes[bytes.count - 1] ^= 1
    fields[key] = .string(Base64URL.encode(bytes))
    reject("변조 \(key)") { _ = try P.Receipt(data(.object(fields)), challenge: goldChallenge, binding: goldBinding, now: 1_800_000_000_000) }
}
let wrongDevice = try P.Binding(macID: goldBinding.macID, hostPin: goldBinding.hostPin, deviceSPKI: m.binding.deviceSPKI)
reject("다른 기기의 challenge") { _ = try P.Challenge(data(gold["challengeResponse"]!), binding: wrongDevice, now: 1_800_000_000_000) }
let wrongDeviceChallenge = try P.Challenge(data(changed(gold["challengeResponse"]!, "deviceId", .string(wrongDevice.deviceID))), binding: wrongDevice, now: 1_800_000_000_000)
reject("서명된 다른 기기 receipt") { _ = try P.Receipt(data(gold["ownerReceipt"]!), challenge: wrongDeviceChallenge, binding: wrongDevice, now: 1_800_000_000_000) }
for key in ["nonce", "challengeId"] {
    let changedChallenge = try P.Challenge(data(changed(gold["challengeResponse"]!, key, .string(Base64URL.encode(Data(repeating: 3, count: 32))))), binding: goldBinding, now: 1_800_000_000_000)
    reject("서명된 challenge 결속 \(key)") { _ = try P.Receipt(data(gold["ownerReceipt"]!), challenge: changedChallenge, binding: goldBinding, now: 1_800_000_000_000) }
}
let otherHost = try P.Binding(macID: m.binding.macID, hostPin: m.binding.hostPin, deviceSPKI: goldBinding.deviceSPKI)
reject("다른 host pin") { _ = try P.Receipt(data(gold["ownerReceipt"]!), challenge: goldChallenge, binding: otherHost, now: 1_800_000_000_000) }
let reply: J = .object(["ok": .bool(true), "method": .string("owner-tailnet-v1"), "macID": .string(goldBinding.macID), "ownerEnrollmentVersion": .integer(1), "ownerReceipt": gold["ownerReceipt"]!])
_ = try P.ownerReply(data(reply), binding: goldBinding)
for key in ["recognitionKey", "proof", "name", "cable", "unknown"] {
    reject("kind20 정확 5필드 \(key)") { _ = try P.ownerReply(data(changed(reply, key, .string("forbidden"))), binding: goldBinding) }
}
for bad: J in [.bool(true), .number("1.0"), .string("1"), .null] {
    reject("ownerEnrollmentVersion 엄격 정수") { _ = try P.ownerReply(data(changed(reply, "ownerEnrollmentVersion", bad)), binding: goldBinding) }
}
let request = try J.parse(P.ownerRequest(goldChallenge, binding: goldBinding, name: "CCR iPad", model: "synthetic"))
try check(Set(object(request).keys) == Set(["v", "method", "proof", "name", "model", "ownerEnrollment"]), "kind19 cable 없음")
try check(object(request)["proof"] == .string(""), "kind19 빈 proof")
for (status, body) in [(401, #"{"error":"CREDENTIAL_EXPIRED","extra":true}"#), (503, #"{"error":"CREDENTIAL_EXPIRED"}"#), (401, #"{"error":"UNKNOWN"}"#)] {
    reject("오류 exact/status 일치") { _ = try P.error(Data(body.utf8), status: status) }
}

let success = try Memory(readbackGolden), engine = success.engine()
let grant = try success.ensure(engine).get()
try check(success.requests.map(\.0) == [.challenge, .enroll] && success.writes == 2, "원문 저장/readback 후 발급 저장")
try check(success.requests[1].1 == success.enrollBody, "golden과 같은 enroll 원문")
try check(try success.ensure(engine).get() == grant && success.requests.count == 2, "자기 유효 자격 재사용")
let authorized = try engine.authorizedRequest(path: "/v1/catalog", method: "GET")
try check(authorized.url?.absoluteString == P.origin + "/v1/catalog" && authorized.value(forHTTPHeaderField: "Authorization") == grant.authorizationValue, "자기 bearer 보호 API 요청")
try check(authorized.value(forHTTPHeaderField: "X-Canvas-Token") == nil && authorized.value(forHTTPHeaderField: "x-ccr-audio-device") == nil && !authorized.httpShouldHandleCookies, "다른 자격 namespace 불변")
for path in ["https://other.invalid/v1/catalog", "//other.invalid/v1/catalog", "/v1/catalog?origin=other", "/v1/catalog#x", "/v1/%2e%2e/catalog", "/v1/devices/enroll"] {
    reject("보호 API path 탈출") { _ = try engine.authorizedRequest(path: path, method: "GET") }
}
reject("보호 API method 불일치") { _ = try engine.authorizedRequest(path: "/v1/catalog", method: "POST") }
try check(!String(describing: grant).contains(String(repeating: "a", count: 64)) && !String(reflecting: grant).contains(String(repeating: "a", count: 64)), "자격 출력 비공개")

let concurrent = try Memory(readbackGolden); concurrent.holdChallenge = true
let one = concurrent.engine(); var completions = 0
for _ in 0..<8 { one.ensure { _ in completions += 1 } }
try check(concurrent.requests.count == 1, "singleflight")
concurrent.parked?(concurrent.response(concurrent.fixture["challengeResponse"]!)); settle { completions == 8 }
try check(concurrent.receiptCalls == 1 && concurrent.requests.count == 2, "동시 취득 한 번")
let cancelled = try Memory(readbackGolden); cancelled.holdChallenge = true
let cancelledEngine = cancelled.engine(); var cancelledDone = false
cancelledEngine.ensure { _ in cancelledDone = true }; cancelledEngine.cancel()
cancelled.parked?(cancelled.response(cancelled.fixture["challengeResponse"]!))
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
try check(cancelledDone && cancelled.writes == 0 && cancelled.receiptCalls == 0, "취소 후 늦은 결과 저장 0")
let stale = try Memory(readbackGolden); stale.holdChallenge = true
let staleEngine = stale.engine(); var staleDone = false
staleEngine.ensure { _ in staleDone = true }; stale.current = false
stale.parked?(stale.response(stale.fixture["challengeResponse"]!)); settle { staleDone }
try check(stale.writes == 0 && stale.receiptCalls == 0, "stale binding 저장 0")
let cas = try Memory(readbackGolden); cas.casFails = true
reject("CAS 실패") { _ = try cas.ensure(cas.engine()).get() }
try check(cas.requests.map(\.0) == [.challenge], "CAS 실패 시 enroll 송신 0")
let grantCAS = try Memory(readbackGolden); grantCAS.failOnWrite = 2
let grantCASEngine = grantCAS.engine()
reject("credential 저장 CAS 실패") { _ = try grantCAS.ensure(grantCASEngine).get() }
try check(grantCASEngine.credential == nil && object(try J.parse(grantCAS.raw!, limit: 1_048_576))["credential"] == .null, "저장 실패를 성공으로 반환하지 않음")
let lateEnroll = try Memory(readbackGolden); lateEnroll.parkRoute = .enroll
let lateEngine = lateEnroll.engine(); var lateFinished = false
lateEngine.ensure { _ in lateFinished = true }; settle { lateEnroll.parked != nil }
let beforeCancel = lateEnroll.raw
lateEngine.cancel(); lateEnroll.parked?(lateEnroll.response(lateEnroll.credential))
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
try check(lateFinished && lateEnroll.raw == beforeCancel && lateEngine.credential == nil && lateEnroll.writes == 1, "취소 epoch의 늦은 발급 응답 저장 0")
let corruptRead = try Memory(readbackGolden); corruptRead.readbackCorrupts = true
reject("쓰기 후 readback 불일치") { _ = try corruptRead.ensure(corruptRead.engine()).get() }
try check(corruptRead.requests.map(\.0) == [.challenge] && corruptRead.raw != nil, "손상 보존·송신 중단")
let corrupt = try Memory(readbackGolden); corrupt.raw = Data("{broken".utf8)
let previousCorrupt = corrupt.raw
reject("손상 load") { _ = try corrupt.ensure(corrupt.engine()).get() }
try check(corrupt.raw == previousCorrupt && corrupt.requests.isEmpty, "손상 load failclosed 보존")
let lost = try Memory(readbackGolden); lost.loseEnroll = true
reject("응답 유실") { _ = try lost.ensure(lost.engine()).get() }
let original = lost.raw; lost.loseEnroll = false
let rebound = try Memory(readbackGolden)
let originalJSON = try J.parse(original!, limit: 1_048_576)
rebound.raw = data(changed(originalJSON, "binding", changed(rebound.binding.json, "origin", .string("https://wrong.invalid"))))
let beforeRebound = rebound.raw
reject("다른 binding pending") { _ = try rebound.ensure(rebound.engine()).get() }
try check(rebound.raw == beforeRebound && rebound.requests.isEmpty, "다른 binding 원문 보존·발급 0")
let restarted = lost.engine(); _ = try lost.ensure(restarted).get()
try check(lost.requests.map(\.0) == [.challenge, .enroll, .enroll] && lost.requests[1].1 == lost.requests[2].1, "재시작 동일 원문만 전송")
let expired = try Memory(readbackGolden); expired.loseEnroll = true
reject("유실 pending 준비") { _ = try expired.ensure(expired.engine()).get() }
expired.now += 31_000; expired.loseEnroll = false
_ = try expired.ensure(expired.engine()).get()
try check(expired.requests.map(\.0) == [.challenge, .enroll, .readbackChallenge, .readback], "만료 후 신규 enroll 없이 fresh signed readback")
try check(try J.parse(expired.requests.last!.1) == expired.fixture["readbackRequest"]!, "golden readback 서명 요청")
let expiresDuringSave = try Memory(readbackGolden)
expiresDuringSave.raw = original; expiresDuringSave.now += 31_000; expiresDuringSave.parkRoute = .readback
let expiresDuringSaveEngine = expiresDuringSave.engine()
var expiresDuringSaveResult: Result<P.Credential, Error>?
expiresDuringSaveEngine.ensure { expiresDuringSaveResult = $0 }
settle { expiresDuringSave.parked != nil }
let pendingBeforeExpiry = object(try J.parse(expiresDuringSave.raw!, limit: 1_048_576))["pending"]!
let expiryDuringSave = expiresDuringSave.now + 1
let expiringResponse = changed(expiresDuringSave.credential, "expiresAt", .integer(expiryDuringSave))
let expiringGrant = try P.Credential(data(expiringResponse), binding: expiresDuringSave.binding, observedAt: expiresDuringSave.now)
expiresDuringSave.onWrite = { _ in expiresDuringSave.now = expiryDuringSave }
expiresDuringSave.parked?(expiresDuringSave.response(expiringResponse))
settle { expiresDuringSaveResult != nil }
reject("CAS/readback 중 만료된 grant 성공 반환 금지") { _ = try expiresDuringSaveResult!.get() }
try check(expiresDuringSaveEngine.credential == nil && expiresDuringSaveEngine.phase == .waiting,
          "저장 중 만료 뒤 메모리 ready 차단")
reject("저장 중 만료 뒤 보호 요청 0") { _ = try expiresDuringSaveEngine.authorizedRequest(path: "/v1/catalog", method: "GET") }
let savedAfterExpiry = object(try J.parse(expiresDuringSave.raw!, limit: 1_048_576))
try check(savedAfterExpiry["pending"] == changed(pendingBeforeExpiry, "acceptedTokenHash", .string(expiringGrant.tokenHash)),
          "저장 중 만료도 원 pending·body·digest 보존")
try check(savedAfterExpiry["credential"] == .object(["response": .string(Base64URL.encode(data(expiringResponse))),
          "observedAt": .integer(expiryDuringSave - 1)]), "저장 중 만료도 저장 자격 원문 보존")
try check(savedAfterExpiry["history"] == .array([]) && savedAfterExpiry["renewalRequired"] == .bool(false) &&
          savedAfterExpiry["terminal"] == .string("") && savedAfterExpiry["rejectedTokenHash"] == .string(""),
          "저장 중 만료를 확정 만료·거절 이력으로 바꾸지 않음")
try check(expiresDuringSave.requests.map(\.0) == [.readbackChallenge, .readback] && expiresDuringSave.receiptCalls == 0,
          "저장 중 만료로 새 enroll·신뢰 발급·renew 0")
for (status, code) in [(404,"ENROLLMENT_OPERATION_UNCONFIRMED"),(409,"ENROLLMENT_IDENTITY_CHANGED"),(409,"CHALLENGE_CONFLICT"),(503,"ENROLLMENT_PROVIDER_UNAVAILABLE")] {
    let blocked = try Memory(readbackGolden); blocked.raw = original; blocked.now += 31_000
    blocked.responseOverride = (status, .object(["error": .string(code)]))
    reject("복구 실패 pending 보존") { _ = try blocked.ensure(blocked.engine()).get() }
    let record = object(try J.parse(blocked.raw!, limit: 1_048_576))
    try check(record["pending"] != .null && record["history"] == .array([]) && blocked.requests.map(\.0) == [.readbackChallenge], "오류가 신규등록 권한이 되지 않음")
}
let mismatch = try Memory(readbackGolden); mismatch.raw = original; mismatch.now += 31_000
mismatch.readbackChallengeOverride = changed(mismatch.fixture["readbackChallenge"]!, "requestDigest", .string(String(repeating: "b", count: 64)))
reject("readback digest 불일치") { _ = try mismatch.ensure(mismatch.engine()).get() }
try check(mismatch.signCalls == 0 && mismatch.requests.count == 1, "digest 불일치 서명/전송 0")
for bad: J in [.bool(true), .number("1800000060000.0"), .string("1800000060000"), .null, .number("9007199254740992")] {
    reject("readback expiry 엄격") { _ = try P.Readback(data(changed(m.fixture["readbackChallenge"]!, "expiresAt", bad)), challenge: m.challenge, digest: P.requestDigest(m.enrollBody), binding: m.binding, now: m.now + 31_000) }
    reject("credential expiry 엄격") { _ = try P.Credential(data(changed(m.credential, "expiresAt", bad)), binding: m.binding, observedAt: m.now) }
}
let confirmed = try Memory(readbackGolden); confirmed.raw = original; confirmed.now += 31_000
confirmed.responseOverride = (401, .object(["error": .string("CREDENTIAL_EXPIRED")]))
let renewal = confirmed.engine()
reject("확정 원 credential 만료") { _ = try confirmed.ensure(renewal).get() }
let archived = object(try J.parse(confirmed.raw!, limit: 1_048_576))
try check(archived["pending"] == .null && archived["renewalRequired"] == .bool(true), "확정401만 이력으로 이동")
let before = confirmed.requests.count
reject("자동 신규등록 금지") { _ = try confirmed.ensure(renewal).get() }
try check(confirmed.requests.count == before, "명시적 trusted renew 대기")
let malformed = try Memory(readbackGolden); malformed.raw = original; malformed.now += 31_000
malformed.responseOverride = (401, .object(["error": .string("CREDENTIAL_EXPIRED"), "extra": .bool(true)]))
reject("오류 추가키") { _ = try malformed.ensure(malformed.engine()).get() }
try check(object(try J.parse(malformed.raw!, limit: 1_048_576))["pending"] != .null, "malformed 만료 이력 이동 금지")
let revoked = try Memory(readbackGolden); revoked.responseOverride = (403, .object(["error": .string("DEVICE_REVOKED")]))
let denied = revoked.engine()
reject("revoked terminal") { _ = try revoked.ensure(denied).get() }
let deniedCount = revoked.requests.count
reject("revoked 재진입") { _ = try revoked.ensure(revoked.engine()).get() }
try check(revoked.requests.count == deniedCount, "거절 신뢰 재발급 0")

let other = try Memory(readbackGolden); other.token = String(repeating: "b", count: 64)
let otherEngine = other.engine(); let otherGrant = try other.ensure(otherEngine).get()
var late: Result<P.Credential, Error>?
otherEngine.unauthorized(grant, status: 401, body: data(.object(["error": .string("CREDENTIAL_INVALID")]))) { late = $0 }
settle { late != nil }
try check(try late!.get() == otherGrant && other.requests.count == 2, "늦은 옛401 새 자격 거절 금지")
let refused = try Memory(readbackGolden), refusedEngine = refused.engine()
let refusedGrant = try refused.ensure(refusedEngine).get(); refused.now += 31_000
var refusal: Result<P.Credential, Error>?
refusedEngine.unauthorized(refusedGrant, status: 401, body: data(.object(["error": .string("CREDENTIAL_INVALID")]))) { refusal = $0 }
settle { refusal != nil }
reject("실제 거절된 자기 credential 재수용 금지") { _ = try refusal!.get() }
try check(refusedEngine.credential == nil && refused.requests.map(\.0) == [.challenge, .enroll, .readbackChallenge, .readback], "현재401 원 작업 readback만 허용")
var denyResult: Result<P.Credential, Error>?
refusedEngine.unauthorized(refusedGrant, status: 403, body: data(.object(["error": .string("OWNER_TRUST_DENIED")]))) { denyResult = $0 }
settle { denyResult != nil }
try check(object(try J.parse(refused.raw!, limit: 1_048_576))["terminal"] == .string("OWNER_TRUST_DENIED"), "현재403 terminal 저장")
for (status, code) in [(401, "CREDENTIAL_INVALID"), (403, "DEVICE_REVOKED"), (403, "OWNER_TRUST_DENIED")] {
    let failed = try Memory(readbackGolden), lifecycle = failed.engine()
    let refused = try failed.ensure(lifecycle).get()
    failed.now += 31_000; failed.casFails = true
    let beforeFailure = failed.raw
    var rejection: Result<P.Credential, Error>?
    lifecycle.unauthorized(refused, status: status, body: data(.object(["error": .string(code)]))) { rejection = $0 }
    settle { rejection != nil }
    reject("거절 저장 실패를 성공으로 반환하지 않음 \(code)") { _ = try rejection!.get() }
    try check(lifecycle.credential == nil && failed.raw == beforeFailure, "CAS 실패에도 메모리 거절 유지 \(code)")
    reject("CAS 실패 뒤 보호 요청 거절 \(code)") { _ = try lifecycle.authorizedRequest(path: "/v1/catalog", method: "GET") }
    reject("CAS 실패 뒤 ensure 재수용 0 \(code)") { _ = try failed.ensure(lifecycle).get() }
    failed.casFails = false
    reject("저장 복구 뒤에도 거절된 옛 grant 재수용 0 \(code)") { _ = try failed.ensure(lifecycle).get() }
    lifecycle.cancel()
    let nextEpoch = failed.engine()
    reject("소비자 교체 뒤에도 같은 binding 거절 유지 \(code)") { _ = try failed.ensure(nextEpoch).get() }
    try check(nextEpoch.credential == nil && failed.requests.filter { $0.0 == .enroll }.count == 1, "거절 자격 자동 재발급 없음 \(code)")
}
for (status, code) in [(401, "CREDENTIAL_INVALID"), (403, "DEVICE_REVOKED")] {
    let failed = try Memory(readbackGolden), lifecycle = failed.engine()
    let rejected = try failed.ensure(lifecycle).get(); failed.now += 31_000; failed.loadFails = true
    var rejection: Result<P.Credential, Error>?
    lifecycle.unauthorized(rejected, status: status, body: data(.object(["error": .string(code)]))) { rejection = $0 }
    settle { rejection != nil }
    reject("load 실패 앞 메모리 격리 \(code)") { _ = try rejection!.get() }
    try check(lifecycle.credential == nil, "Keychain 읽기 실패에도 cached 자격 없음 \(code)")
    reject("load 실패 뒤 authorizedRequest 거절 \(code)") { _ = try lifecycle.authorizedRequest(path: "/v1/catalog", method: "GET") }
    reject("load 실패 뒤 ensure 재수용 0 \(code)") { _ = try failed.ensure(lifecycle).get() }
    failed.loadFails = false
    reject("load 복구 뒤에도 거절된 자격 재수용 0 \(code)") { _ = try failed.ensure(lifecycle).get() }
}
for (status, code) in [(401, "CREDENTIAL_INVALID"), (403, "DEVICE_REVOKED")] {
    other.loadFails = true
    var result: Result<P.Credential, Error>?
    otherEngine.unauthorized(grant, status: status, body: data(.object(["error": .string(code)]))) { result = $0 }
    settle { result != nil }
    try check(try result!.get() == otherGrant && otherEngine.credential == otherGrant, "읽기 오류 중 늦은 옛 거절은 새 cached 자격 보존 \(code)")
    other.loadFails = false
}
var emptyCacheRefusalFailures: [String] = []
for (status, code) in [(401, "CREDENTIAL_INVALID"), (403, "DEVICE_REVOKED")] {
    for recreateBeforeRefusal in [false, true] {
        let memory = try Memory(readbackGolden)
        var lifecycle = memory.engine()
        let rejected = try memory.ensure(lifecycle).get()
        let original = memory.raw
        let originalRequests = memory.requests.count
        memory.now += 31_000; memory.loadFails = true
        reject("ensure 읽기 오류로 접근 캐시 비우기 \(code)") { _ = try memory.ensure(lifecycle).get() }
        try check(lifecycle.credential == nil && lifecycle.phase == .waiting, "거절 전 캐시 빈 waiting \(code)")
        if recreateBeforeRefusal { lifecycle.cancel(); lifecycle = memory.engine() }
        var result: Result<P.Credential, Error>?
        lifecycle.unauthorized(rejected, status: status, body: data(.object(["error": .string(code)]))) { result = $0 }
        settle { result != nil }
        reject("캐시 빈 거절과 읽기 실패 반환 \(code)") { _ = try result!.get() }
        try check(memory.raw == original && memory.requests.count == originalRequests, "읽기 실패 동안 저장과 등록 요청 0 \(code)")
        reject("캐시 빈 거절 직후 보호 요청 0 \(code)") { _ = try lifecycle.authorizedRequest(path: "/v1/catalog", method: "GET") }
        memory.loadFails = false
        for recreateAfterRefusal in [false, true] {
            if recreateAfterRefusal { lifecycle.cancel(); lifecycle = memory.engine() }
            let recovery = memory.ensure(lifecycle)
            let accepted: Bool
            if case .success = recovery { accepted = true } else { accepted = false }
            let authorized = (try? lifecycle.authorizedRequest(path: "/v1/catalog", method: "GET")) != nil
            if accepted || lifecycle.credential != nil || authorized {
                let failure = "\(code) recreateBefore=\(recreateBeforeRefusal) recreateAfter=\(recreateAfterRefusal) 재수용=\(accepted) authorizedRequest=\(authorized)"
                emptyCacheRefusalFailures.append(failure)
                print("RED 캐시 빈 거절 이력: " + failure)
            }
        }
        try check(memory.requests.filter { $0.0 == .enroll }.count == 1 && memory.receiptCalls == 1,
                  "캐시 빈 거절 복구 뒤 새 enroll·신뢰 발급 0 \(code)")
        let journal = object(try J.parse(memory.raw!, limit: 1_048_576))
        let originalJournal = object(try J.parse(original!, limit: 1_048_576))
        let expectedPending = status == 401 ? changed(originalJournal["pending"]!, "mode", .string("readback")) : originalJournal["pending"]!
        try check(journal["pending"] == expectedPending && journal["credential"] == originalJournal["credential"],
                  "캐시 빈 거절 원문·기존 자격 보존 \(code)")
        try check(status == 401 ? journal["rejectedTokenHash"] == .string(rejected.tokenHash) && journal["terminal"] == .string("") :
                  journal["terminal"] == .string(code) && journal["rejectedTokenHash"] == .string(""),
                  "캐시 빈 거절 token401과 terminal403 분리 \(code)")
        try check(journal["history"] == .array([]) && journal["renewalRequired"] == .bool(false),
                  "캐시 빈 거절로 확정 만료·renew 전환 없음 \(code)")
    }
    for recreateBeforeRefusal in [false, true] {
        let memory = try Memory(readbackGolden)
        var lifecycle = memory.engine()
        let old = try memory.ensure(lifecycle).get()
        memory.raw = other.raw
        let latest = try memory.ensure(lifecycle).get()
        try check(latest == otherGrant && latest != old, "G 뒤 H 최신 수용 \(code)")
        let latestRaw = memory.raw, requests = memory.requests.count
        memory.loadFails = true
        reject("H 수용 후 읽기 실패로 캐시 비우기 \(code)") { _ = try memory.ensure(lifecycle).get() }
        try check(lifecycle.credential == nil, "H도 접근 캐시는 비움 \(code)")
        if recreateBeforeRefusal { lifecycle.cancel(); lifecycle = memory.engine() }
        var result: Result<P.Credential, Error>?
        lifecycle.unauthorized(old, status: status, body: data(.object(["error": .string(code)]))) { result = $0 }
        settle { result != nil }
        try check(lifecycle.credential == nil && memory.raw == latestRaw && memory.requests.count == requests,
                  "캐시 빈 옛 G 거절이 H 저장을 변경하지 않음 \(code)")
        memory.loadFails = false
        try check(try memory.ensure(lifecycle).get() == latest, "캐시 빈 옛 G 거절 뒤 H 보존 \(code)")
        try check(try lifecycle.authorizedRequest(path: "/v1/catalog", method: "GET").value(forHTTPHeaderField: "Authorization") == latest.authorizationValue,
                  "복구 뒤 보호 요청에는 H만 사용 \(code)")
        try check(memory.raw == latestRaw && memory.requests.count == requests && memory.receiptCalls == 1,
                  "늦은 G 거절로 새 enroll·신뢰 발급·renew 0 \(code)")
    }
}
try check(emptyCacheRefusalFailures.isEmpty, "캐시 빈 거절 복구 후 G 재수용 0 실패: " + emptyCacheRefusalFailures.joined(separator: "; "))
let readbackFailed = try Memory(readbackGolden), readbackFailedEngine = readbackFailed.engine()
let readbackRefused = try readbackFailed.ensure(readbackFailedEngine).get()
readbackFailed.responseOverride = (503, .object(["error": .string("ENROLLMENT_PROVIDER_UNAVAILABLE")]))
var readbackRefusal: Result<P.Credential, Error>?
readbackFailedEngine.unauthorized(readbackRefused, status: 401, body: data(.object(["error": .string("CREDENTIAL_INVALID")]))) { readbackRefusal = $0 }
settle { readbackRefusal != nil }
try check(readbackFailedEngine.credential == nil, "거절 후 readback 실패도 cached 자격 없음")
success.current = false
reject("신뢰 변경 보호 API 거절") { _ = try engine.authorizedRequest(path: "/v1/catalog", method: "GET") }
engine.cancel()
reject("취소 epoch 보호 API 거절") { _ = try engine.authorizedRequest(path: "/v1/catalog", method: "GET") }

print("iPad owner receipt 메모리 검사 \(assertions)개 통과. 실제 키·Keychain·TLS·HTTP·앱·음성 실행 0.")
let beforeSignedPayload = assertions
try signedPayloadChecks()
print("유효 Host 서명 뒤 payload·canonical encoding 메모리 검사 \(assertions - beforeSignedPayload)개 통과. 테스트 메모리 Host 키만 사용.")
let beforeRuntime = assertions
try runtimeChecks()
print("실제 StreamClient 등록 extension 메모리 검사 \(assertions - beforeRuntime)개 통과.")
let beforeRenewal = assertions
try renewalRuntimeChecks()
print("실제 제품 wrapper의 확정 만료 자동 갱신 메모리 검사 \(assertions - beforeRenewal)개 통과.")
