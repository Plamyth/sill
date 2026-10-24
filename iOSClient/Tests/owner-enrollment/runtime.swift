import Foundation
import StreamProtocol

final class MemoryDeviceKey {
    let point: Data
    var sign: ((Data) throws -> Data)?
    init(_ point: Data, sign: ((Data) throws -> Data)? = nil) { self.point = point; self.sign = sign }
}
struct RemoteIdentity { let privateKey: MemoryDeviceKey; let fingerprint: Data }
enum DeviceIdentity {
    static var value: RemoteIdentity?
    static func existing() -> RemoteIdentity? { value }
}
enum MemorySignatureAlgorithm { case ecdsaSignatureMessageX962SHA256 }
func SecKeyCopyPublicKey(_ key: MemoryDeviceKey) -> MemoryDeviceKey? { key }
func SecKeyCopyExternalRepresentation(_ key: MemoryDeviceKey, _ error: UnsafeMutableRawPointer?) -> CFData? { key.point as CFData }
func SecKeyCreateSignature(_ key: MemoryDeviceKey, _ algorithm: MemorySignatureAlgorithm, _ message: CFData,
                           _ error: UnsafeMutableRawPointer?) -> CFData? {
    if let sign = key.sign {
        guard let bytes = try? sign(message as Data) else { return nil }
        return bytes as CFData
    }
    guard let memory = runtimeMemory else { return nil }
    let bytes = message as Data
    let request: J
    if bytes == memory.receipt.proofMessage { request = memory.fixture["enrollRequest"]! }
    else if bytes == memory.readbackMessage { request = memory.fixture["readbackRequest"]! }
    else { return nil }
    return try! P.decode(text(object(request)["signature"]!), maximum: 72) as CFData
}
enum Bundle {
    static let main = Resource()
    static var url: URL?
    struct Resource {
        func url(forResource: String, withExtension: String) -> URL? { Bundle.url }
    }
}
final class NWConnection {
    enum State { case ready, cancelled }
    var state: State = .ready
    var pin: Data?
    var alpn: String? = "sill/1"
}
enum RemoteTLS {
    static let sessionALPN = "sill/1"
    static func negotiatedALPN(_ c: NWConnection) -> String? { c.alpn }
    static func peerFingerprint(_ c: NWConnection) -> Data? { c.pin }
}
enum ClientStatsReporter { static let hardwareIdentifier = "synthetic-ipad" }
final class IPadEnrollmentStore {
    init(deviceID: String) {}
    func load() throws -> Data? {
        if runtimeMemory!.loadFails { throw IPadEnrollmentFailure.storage }
        return runtimeMemory!.raw
    }
    func compareAndSwap(_ expected: Data?, _ next: Data) throws {
        guard let memory = runtimeMemory, !memory.casFails, memory.raw == expected else { throw IPadEnrollmentFailure.storage }
        memory.raw = next; memory.writes += 1
        memory.onWrite?(next)
    }
}
enum IPadEnrollmentHTTPPost {
    static func post(_ route: IPadDeviceEnrollment.Route, body: Data,
                     done: @escaping (Result<IPadDeviceEnrollment.HTTPReply, Error>) -> Void) -> IPadDeviceEnrollment.Cancel {
        let memory = runtimeMemory!
        memory.requests.append((route, body))
        if let handler = memory.postHandler { done(handler(route, body)); return {} }
        switch route {
        case .challenge:
            if memory.holdChallenge { memory.parked = done }
            else { done(memory.response(memory.fixture["challengeResponse"]!)) }
        case .enroll, .readback: done(memory.response(memory.credential))
        case .readbackChallenge: done(memory.response(memory.fixture["readbackChallenge"]!))
        }
        return {}
    }
}
final class IPadOwnerReceiptTransport {
    private let current: () -> Bool
    init(queue: DispatchQueue, profile: OwnerMacBootstrap, identity: RemoteIdentity,
         binding: P.Binding, current: @escaping () -> Bool) { self.current = current }
    func start(_ challenge: P.Challenge, name: String, model: String, done: @escaping (Result<Data, Error>) -> Void) {
        guard current(), let memory = runtimeMemory else { done(.failure(IPadEnrollmentFailure.stale)); return }
        memory.receiptCalls += 1
        if let handler = memory.receiptHandler {
            do { done(.success(try handler(challenge))) } catch { done(.failure(error)) }
            return
        }
        done(.success(data(object(memory.fixture["enrollRequest"]!)["ownerReceipt"]!)))
    }
    func cancel() {}
}
final class StreamClient {
    struct Session { var macID: String? }
    struct Saved { let macID: String; let fingerprintData: Data?; var revoked: Bool?; var newKey: Bool?; var homeTLS: Bool? }
    var appInForeground = true
    var connected = false
    var connection: NWConnection? { didSet { if oldValue !== connection { cancelOwnerEnrollment() } } }
    var session: Session?
    var savedMacs: [Saved] = [] { didSet { ownerEnrollmentTrustChanged() } }
    var ownerEnrollment: IPadDeviceEnrollment?
    var ownerEnrollmentPeer: ObjectIdentifier?
    var ownerEnrollmentRefusals: [P.Binding: IPadDeviceEnrollment.Refusals] = [:]
    let queue = DispatchQueue(label: "memory-runtime")
}
var runtimeMemory: Memory?
func runtimeChecks() throws {
    func client(_ memory: Memory) -> StreamClient {
        runtimeMemory = memory
        DeviceIdentity.value = .init(privateKey: .init(Data(memory.binding.deviceSPKI.suffix(65))), fingerprint: memory.binding.deviceFingerprint)
        let client = StreamClient()
        let peer = NWConnection(); peer.pin = memory.binding.hostPin
        client.connection = peer; client.session = .init(macID: memory.binding.macID)
        client.savedMacs = [.init(macID: memory.binding.macID, fingerprintData: memory.binding.hostPin, homeTLS: true)]
        return client
    }
    Bundle.url = URL(fileURLWithPath: CommandLine.arguments[2])
    let memory = try Memory(readbackGolden), stream = client(memory)
    stream.connected = true
    stream.resumeOwnerEnrollment()
    settle { stream.ownerEnrollmentCredential != nil }
    try check(memory.requests.map(\.0) == [.challenge, .enroll] && memory.receiptCalls == 1, "실제 StreamClient extension 등록 배선")
    try check(try stream.ownerEnrollmentAuthorizedRequest(path: "/v1/snapshot", method: "GET").value(forHTTPHeaderField: "Authorization") == stream.ownerEnrollmentCredential!.authorizationValue, "실제 accessor 별도 자기 bearer")
    stream.appInForeground = false; stream.cancelOwnerEnrollment()
    reject("background accessor") { _ = try stream.ownerEnrollmentAuthorizedRequest(path: "/v1/catalog", method: "GET") }
    stream.appInForeground = true; stream.resumeOwnerEnrollment()
    settle { stream.ownerEnrollmentCredential != nil }
    try check(memory.requests.count == 2, "foreground 저장 자격 재사용")
    stream.savedMacs[0].revoked = true
    try check(stream.ownerEnrollment == nil && stream.ownerEnrollmentCredential == nil, "저장 신뢰 취소 시 즉시 중단")
    for mode in ["offline", "no-key", "wrong-peer", "plain", "no-profile", "wrong-saved", "revoked", "new-key"] {
        let memory = try Memory(readbackGolden), stream = client(memory)
        switch mode {
        case "offline": stream.connection?.state = .cancelled
        case "no-key": DeviceIdentity.value = nil
        case "wrong-peer": stream.connection?.pin = Data(repeating: 8, count: 32)
        case "plain": stream.connection?.alpn = nil
        case "no-profile": Bundle.url = nil
        case "wrong-saved": stream.savedMacs = []
        case "revoked": stream.savedMacs[0].revoked = true
        case "new-key": stream.savedMacs[0].newKey = true
        default: break
        }
        stream.connected = true
        stream.resumeOwnerEnrollment()
        try check(stream.ownerEnrollment == nil && memory.requests.isEmpty && memory.raw == nil, "현재 peer/profile/신뢰/자체키 경계 \(mode)")
        Bundle.url = URL(fileURLWithPath: CommandLine.arguments[2])
    }
    let held = try Memory(readbackGolden); held.holdChallenge = true
    let heldStream = client(held); heldStream.connected = true; heldStream.resumeOwnerEnrollment()
    heldStream.connection = NWConnection()
    held.parked?(held.response(held.fixture["challengeResponse"]!))
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    try check(held.raw == nil && held.receiptCalls == 0 && heldStream.ownerEnrollment == nil, "실제 peer 교체 후 늦은 응답 저장 0")
    let upgraded = try Memory(readbackGolden), upgradedStream = client(upgraded)
    upgradedStream.savedMacs[0].homeTLS = nil
    upgradedStream.connected = true; upgradedStream.resumeOwnerEnrollment()
    try check(upgraded.requests.isEmpty, "아직 보강되지 않은 saved TLS 신뢰")
    upgradedStream.savedMacs[0].homeTLS = true
    settle { upgradedStream.ownerEnrollmentCredential != nil }
    try check(upgraded.requests.map(\.0) == [.challenge, .enroll], "인증 후 saved trust 보강 시 실제 시작")
    let rejected = try Memory(readbackGolden), rejectedStream = client(rejected)
    rejectedStream.connected = true; rejectedStream.resumeOwnerEnrollment()
    settle { rejectedStream.ownerEnrollmentCredential != nil }
    let rejectedCredential = rejectedStream.ownerEnrollmentCredential!
    rejected.casFails = true
    var rejectionDone = false
    rejectedStream.ownerEnrollmentUnauthorized(rejectedCredential, status: 403,
        body: data(.object(["error": .string("DEVICE_REVOKED")]))) { _ in rejectionDone = true }
    settle { rejectionDone }
    rejectedStream.cancelOwnerEnrollment(); rejectedStream.resumeOwnerEnrollment()
    try check(rejectedStream.ownerEnrollmentCredential == nil && rejected.requests.count == 2, "실제 runtime 소비자 교체에도 저장 실패 거절 유지")
    reject("실제 runtime 저장 실패 거절 뒤 bearer 없음") { _ = try rejectedStream.ownerEnrollmentAuthorizedRequest(path: "/v1/catalog", method: "GET") }
}
