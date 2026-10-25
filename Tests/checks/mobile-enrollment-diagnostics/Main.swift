import Foundation
import CryptoKit
import StreamProtocol
import os
import Darwin

private struct PrivateError: Error, CustomStringConvertible {
    var description: String { "PRIVATE_ERROR_SENTINEL/path/profile/SPKI/token/key/peer/nonce/payload" }
}

private final class Trace: @unchecked Sendable {
    struct State {
        var connects: [Double] = []
        var sleeps: [Double] = []
        var frames: [Data] = []
        var sendDeadlines: [Double] = []
        var receiveDeadlines: [Double] = []
        var peerChecks = 0
        var invalidations = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var value: State { state.withLock { $0 } }
}

private final class MemoryTransport: MobileEnrollmentTransport {
    let trace: Trace
    let sendError: Error?
    let receiveError: Error?
    let chunks: OSAllocatedUnfairLock<[Data]>
    init(_ trace: Trace, chunks: [Data] = [], sendError: Error? = nil, receiveError: Error? = nil) {
        self.trace = trace; self.sendError = sendError; self.receiveError = receiveError
        self.chunks = OSAllocatedUnfairLock(initialState: chunks)
    }
    func send(_ frame: Data, until deadline: TimeInterval) async throws {
        if let sendError { throw sendError }
        trace.state.withLock { $0.frames.append(frame); $0.sendDeadlines.append(deadline) }
    }
    func receive(until deadline: TimeInterval) async throws -> Data? {
        trace.state.withLock { $0.receiveDeadlines.append(deadline) }
        if let receiveError { throw receiveError }
        while true {
            if let data = chunks.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return data }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func checkPeer() async throws { trace.state.withLock { $0.peerChecks += 1 } }
    func invalidate() { trace.state.withLock { $0.invalidations += 1 } }
}

@main struct Checks {
    static var failures: [String] = []
    static var cases: [[String: Any]] = []
    static let prefix = "[MobileEnrollment] "
    static func check(_ value: Bool, _ label: String) {
        if !value { failures.append(label); Swift.print("ASSERTION FAILED: \(label)") }
    }
    static func logs() -> [String] { HostLog.shared.lines(after: 0).map(\.text).filter { $0.hasPrefix(prefix) } }
    static func reset() { HostLog.shared.configure(keepLines: 256, fileURL: nil) }
    static func has(_ stage: String, _ code: String, retry: Bool = false) -> Bool {
        logs().contains("\(prefix)stage=\(stage) code=\(code) retrying=\(retry)")
    }
    private static func record(_ name: String, _ trace: Trace) {
        let v = trace.value
        cases.append(["name": name, "logs": logs(), "connectDeadlines": v.connects,
            "sleepRequests": v.sleeps, "frameCount": v.frames.count,
            "frameSHA256": v.frames.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
            "payloadSHA256": v.frames.compactMap { raw -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let envelope = object["envelope"] as? [String: Any],
                      let encoded = envelope["payload"] as? String,
                      let payload = Base64URL.decode(encoded) else { return nil }
                return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            },
            "sendDeadlines": v.sendDeadlines, "receiveDeadlines": v.receiveDeadlines,
            "peerChecks": v.peerChecks, "invalidations": v.invalidations])
    }
    @MainActor static func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    private static func dependencies(_ trace: Trace,
                             connect: @escaping @Sendable () throws -> any MobileEnrollmentTransport) -> MobileEnrollmentDependencies {
        var deps = MobileEnrollmentDependencies()
        deps.clock = { .init(milliseconds: 1_800_000_000_000, uptime: 100) }
        deps.connect = { _, deadline in
            trace.state.withLock { $0.connects.append(deadline) }
            return try connect()
        }
        deps.sleep = { seconds in
            trace.state.withLock { $0.sleeps.append(seconds) }
            if seconds == 5 { try await Task.sleep(nanoseconds: 10_000_000_000) }
        }
        return deps
    }
    @MainActor static func runtime(_ identity: HostIdentity, _ host: MobileEnrollment.HostProfile,
                                   _ deps: MobileEnrollmentDependencies) -> MobileEnrollmentHostRuntime {
        MobileEnrollmentHostRuntime(identity: identity, host: host,
            observeActive: { _ in .init(reason: .active, checkedAtMilliseconds: 1_800_000_000_000) },
            currentRemoteAccess: { true }, commandPath: "PRIVATE_ERROR_SENTINEL/socket", dependencies: deps)
    }
    static func frame<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data([10])
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let bytes = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).x963Representation
        let key = RemoteKey.importPrivate(bytes)!
        let identity = HostIdentity(privateKey: key, recognitionKey: Data(repeating: 0, count: 32))!
        let host = try MobileEnrollment.HostProfile(macID: identity.macID,
            trustedFingerprint: Base64URL.encode(identity.fingerprint),
            publicSPKIDER: SPKI.der(point: RemoteKey.publicPoint(key)!))

        reset()
        let profileTrace = Trace()
        let remote = RemoteAccess(identity: identity, dependencies: dependencies(profileTrace) { throw PrivateError() })
        remote.apply(false)
        check(logs().isEmpty && profileTrace.value.connects.isEmpty, "설정 off는 준비·접속·로그 0")
        profileLookupFails.withLock { $0 = true }
        remote.apply(true)
        profileLookupFails.withLock { $0 = false }
        check(has("profilePreparation", "none"), "프로필 준비 실제 시도 로그 누락")
        check(has("profilePreparation", "invalidKey"), "프로필 준비 실패 공개 코드 로그 누락")
        check(remote.mobileEnrollmentRuntime == nil && profileTrace.value.connects.isEmpty,
              "프로필 실패는 기존 return과 connect 0 유지")
        record("profile-failure", profileTrace)

        reset()
        remote.apply(true)
        await settle { !profileTrace.value.connects.isEmpty }
        check(has("profilePreparation", "none") && has("start", "none"), "프로필 성공 후 runtime 시작 로그 누락")
        check(has("connect", "unknown") && has("terminal", "unknown"), "임의 비공개 오류는 unknown으로 종료")
        check(profileTrace.value.connects == [105] && profileTrace.value.sleeps.isEmpty,
              "비공개 초기 connect 예외의 접속 1회·sleep 0 유지")
        remote.stopMobileEnrollment()
        record("profile-success-private-connect-failure", profileTrace)

        let errors: [(Error, String)] = [
            (MobileEnrollmentRuntimeFailure.unsafeEndpoint, "unsafeEndpoint"),
            (MobileEnrollmentRuntimeFailure.invalidFrame, "invalidFrame"),
            (MobileEnrollmentRuntimeFailure.expired, "expired"),
            (MobileEnrollmentRuntimeFailure.clockRollback, "clockRollback"),
            (MobileEnrollmentRuntimeFailure.replay, "replay"),
            (MobileEnrollmentRuntimeFailure.capacity, "capacity"),
            (MobileEnrollmentRuntimeFailure.stopped, "stopped"),
            (MobileEnrollment.Failure.invalidFields, "invalidFields"),
            (MobileEnrollment.Failure.invalidKey, "invalidKey"),
            (MobileEnrollment.Failure.identityMismatch, "identityMismatch"),
            (MobileEnrollment.Failure.invalidTime, "invalidTime"),
            (MobileEnrollment.Failure.invalidSignature, "invalidSignature"),
            (ProviderPeerAnchor.Failure.invalidSocket, "peerInvalidSocket"),
            (ProviderPeerAnchor.Failure.peerUnavailable, "peerUnavailable"),
            (ProviderPeerAnchor.Failure.signatureMismatch, "peerSignatureMismatch"),
            (ProviderPeerAnchor.Failure.pathMismatch, "peerPathMismatch"),
            (ProviderPeerAnchor.Failure.installedCodeMismatch, "peerInstalledCodeMismatch"),
            (ProviderPeerAnchor.Failure.peerChanged, "peerChanged"),
            (PrivateError(), "unknown"),
            (NSError(domain: "PRIVATE_ERROR_SENTINEL", code: 934, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_SENTINEL"]), "unknown")]
        for (error, code) in errors {
            reset()
            let trace = Trace()
            let f = runtime(identity, host, dependencies(trace) { throw error })
            f.start(); f.start()
            await settle { !trace.value.connects.isEmpty }
            check(has("connect", code) && has("terminal", code), "초기 connect 공개 코드 \(code) 로그 누락")
            check(trace.value.connects == [105] && trace.value.sleeps.isEmpty && trace.value.frames.isEmpty,
                  "초기 connect \(code)의 호출수·기한·sleep·frame 불변")
            f.stop(); record("connect-\(code)", trace)
        }

        for (error, code) in [(PrivateError() as Error, "unknown"), (MobileEnrollment.Failure.invalidSignature as Error, "invalidSignature")] {
            reset()
            let trace = Trace()
            let transport = MemoryTransport(trace, sendError: error)
            let f = runtime(identity, host, dependencies(trace) { transport })
            f.start(); await settle { trace.value.invalidations > 0 }
            check(has("handshake", code) && has("terminal", code), "handshake 예외 \(code) 진단 누락")
            check(trace.value.connects == [105] && trace.value.frames.isEmpty && trace.value.peerChecks == 1,
                  "handshake 예외의 기존 connect·peer·전송 불변")
            check(trace.value.sleeps.allSatisfy { $0 == 5 } && trace.value.invalidations >= 2,
                  "handshake 예외의 timer·terminal 정리 불변")
            f.stop(); record("handshake-\(code)", trace)
        }

        reset()
        let retry = Trace()
        let f = runtime(identity, host, dependencies(retry) {
            if retry.value.connects.count <= 10 { throw MobileEnrollmentRuntimeFailure.unavailable }
            throw PrivateError()
        })
        f.start(); await settle { retry.value.connects.count == 11 }
        check(retry.value.connects == Array(repeating: 105, count: 11), "재시도 11회 connect 기한 불변")
        check(retry.value.sleeps == [0.25, 0.5, 1, 2, 4, 8, 16, 30, 30, 30], "기존 backoff 배열 불변")
        check(logs().filter { $0 == "\(prefix)stage=connect code=unavailable retrying=true" }.count == 10,
              "unavailable 기존 재시도만 진단")
        check(has("terminal", "unknown"), "재시도 후 비공개 오류 terminal 누락")
        f.stop(); record("unavailable-backoff", retry)

        reset()
        let normal = Trace()
        HostLog.shared.configure(keepLines: 256, fileURL: output)
        let hc = try MobileEnrollment.HostChallenge(coreGeneration: "10000000-0000-0000-0000-000000000001",
            nonce: Base64URL.encode(Data(repeating: 7, count: 32)), origin: MobileEnrollment.origin)
        let socket = MemoryTransport(normal, chunks: [try frame(hc)])
        let live = runtime(identity, host, dependencies(normal) { socket })
        live.start(); await settle { normal.value.frames.count == 2 }
        check(normal.value.frames.first == Data("{\"op\":\"enrollment.host.attach\",\"schemaVersion\":1}\n".utf8), "attach 바이트 불변")
        check(normal.value.connects == [105] && normal.value.sendDeadlines == [105, 105], "정상 connect·handshake 기한 불변")
        check(has("handshake", "none"), "정상 handshake 완료 로그 누락")
        let before = logs()
        for index in 1...2 {
            let id = String(format: "20000000-0000-0000-0000-%012d", index)
            let nonce = Base64URL.encode(Data(repeating: UInt8(20 + index), count: 32))
            let fingerprint = Base64URL.encode(Data(repeating: 3, count: 32))
            let principal = String(repeating: "a", count: 64), deadline: Int64 = 1_800_000_001_400
            let digest = try MobileEnrollment.hexDigest(MobileEnrollment.activeRequestBytes(coreGeneration: hc.coreGeneration,
                requestId: id, nonce: nonce, deviceFingerprint: fingerprint, ownerPrincipal: principal,
                origin: MobileEnrollment.origin, deadlineMilliseconds: deadline))
            let request = try MobileEnrollment.ActiveChallenge(requestId: id, coreGeneration: hc.coreGeneration,
                nonce: nonce, origin: MobileEnrollment.origin, deviceFingerprint: fingerprint, ownerPrincipal: principal,
                requestDigest: digest, deadlineMilliseconds: deadline, receivedAtMilliseconds: 1_800_000_000_000)
            socket.chunks.withLock { $0.append(try! frame(request)) }
            await settle { normal.value.frames.count == index + 2 }
            check(normal.value.frames.count == index + 2, "정상 active 응답 개수 불변")
            if let raw = normal.value.frames.last,
               let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                let envelope = try MobileEnrollment.Envelope.decode(JSONSerialization.data(withJSONObject: object["envelope"]!))
                _ = try MobileEnrollment.verifyActiveResult(envelope, challenge: request, host: host,
                    nowMilliseconds: 1_800_000_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        check(logs() == before, "정상 active 요청과 idle의 반복 로그 0")
        live.stop(); await settle { has("terminal", "cancelled") || has("terminal", "stopped") }
        check(normal.value.invalidations >= 2 && normal.value.connects.count == 1, "취소 정리와 추가 connect 0")
        record("normal-cancellation", normal)
        check(!logs().isEmpty && HostLog.shared.fileURL == output,
              "기존 HostLog 파일 sink가 디렉터리 열기에 실패해도 ring·runtime 유지")
        HostLog.shared.configure(keepLines: 256, fileURL: nil)

        let allowedStages: Set<String> = ["start", "profilePreparation", "connect", "handshake", "terminal"]
        let allowedCodes = Set(errors.map { $0.1 } + ["none", "unavailable", "cancelled"])
        for item in cases {
            for line in item["logs"] as! [String] {
                let fields = line.dropFirst(prefix.count).split(separator: " ")
                check(fields.count == 3 && !line.contains("PRIVATE_ERROR_SENTINEL"), "로그 필드 상한과 비공개 정보 차단")
                check(allowedStages.contains(String(fields[0].dropFirst(6))) && allowedCodes.contains(String(fields[1].dropFirst(5)))
                    && ["retrying=true", "retrying=false"].contains(String(fields[2])), "정적 공개 stage·code·retry만 허용")
            }
        }
        let report: [String: Any] = ["cases": cases, "failures": failures, "passed": failures.isEmpty,
            "actualSockets": 0, "actualHosts": 0, "keychainCalls": 0, "productionPrintAndHostLog": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("diagnostics.json"))
        Swift.print("diagnostics assertions failed: \(failures.count); cases: \(cases.count); actual sockets=0")
        if !failures.isEmpty { exit(1) }
    }
}
