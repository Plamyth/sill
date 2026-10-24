import Foundation
import Security
import StreamProtocol

var adapterChecks = 0
func require(_ value: @autoclosure () -> Bool, _ label: String) {
    adapterChecks += 1; precondition(value(), label)
}
func refuses(_ label: String, _ body: () throws -> Void) {
    adapterChecks += 1
    do { try body(); fatalError(label) } catch {}
}

final class NWConnection {
    enum State { case ready, failed, cancelled, waiting }
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    var stateUpdateHandler: ((State) -> Void)?
    var pin: Data? = Data(repeating: 7, count: 32)
    var alpn: String? = "sill-owner/1"
    var segments: [(Data?, Bool)] = []
    var sent: [Data] = []
    var cancelled = false
    var sendError = false
    var parked: ((Data?, Int?, Bool, Error?) -> Void)?
    func send(content: Data?, completion: SendCompletion) {
        if let content { sent.append(content) }
        if case .contentProcessed(let done) = completion { done(sendError ? IPadEnrollmentFailure.unavailable : nil) }
    }
    func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, Int?, Bool, Error?) -> Void) {
        if segments.isEmpty { parked = completion; return }
        let row = segments.removeFirst(); completion(row.0, nil, row.1, nil)
    }
    func cancel() { cancelled = true; stateUpdateHandler?(.cancelled) }
}
enum RemoteTLS {
    static func negotiatedALPN(_ connection: NWConnection) -> String? { connection.alpn }
    static func peerFingerprint(_ connection: NWConnection) -> Data? { connection.pin }
}
enum OwnerMacBootstrap { static let alpn = "sill-owner/1" }

let socketQueue = DispatchQueue(label: "owner-receipt-memory-socket")
let syntheticBody = Data(#"{"ok":true}"#.utf8)
let validFrame = StreamMessage(kind: .pairResult, timestamp: 1, isKeyframe: false, payload: syntheticBody).serialized()
func exchange(_ socket: NWConnection, beforeStartCancel: Bool = false) -> (Result<Data, Error>?, IPadOwnerReceiptExchange) {
    let instance = IPadOwnerReceiptExchange(connection: socket, pin: Data(repeating: 7, count: 32), request: Data("request".utf8), queue: socketQueue)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>?
    if beforeStartCancel { instance.cancel() }
    instance.start { result = $0; semaphore.signal() }
    if !beforeStartCancel { precondition(semaphore.wait(timeout: .now() + 1) == .success) }
    socketQueue.sync {}
    return (result, instance)
}
func success(_ result: Result<Data, Error>?) -> Bool { if case .success? = result { return true }; return false }
func socket(frame: Data = validFrame, body: Data = syntheticBody, ended: Bool = false) -> NWConnection {
    let value = NWConnection(); value.segments = [(Data(frame.prefix(14)), ended), (body, false)]; return value
}
let acceptedSocket = socket()
let acceptedExchange = exchange(acceptedSocket)
require(success(acceptedExchange.0) && acceptedSocket.sent.count == 1 && acceptedSocket.cancelled, "실제 exchange 한 번 송신·응답 수용·닫기")
require(acceptedSocket.sent[0].first == 19 && acceptedSocket.sent[0][9] == 0, "실제 kind19 전송")
acceptedExchange.1.start { _ in fatalError("중복 start callback") }; socketQueue.sync {}
require(acceptedSocket.sent.count == 1, "중복 start 송신 없음")
let pinMismatch = socket(); pinMismatch.pin = Data(repeating: 8, count: 32)
require(!success(exchange(pinMismatch).0) && pinMismatch.sent.isEmpty, "잘못된 pin 송신 전 거절")
let alpnMismatch = socket(); alpnMismatch.alpn = "sill/1"
require(!success(exchange(alpnMismatch).0) && alpnMismatch.sent.isEmpty, "잘못된 ALPN 송신 전 거절")
for flag: UInt8 in [1, 2, 255] {
    var frame = validFrame; frame[9] = flag
    require(!success(exchange(socket(frame: frame)).0), "keyframe/unknown flag 거절")
}
var wrongKind = validFrame; wrongKind[0] = 18
require(!success(exchange(socket(frame: wrongKind)).0), "다른 kind 거절")
let nan = StreamMessage(kind: .pairResult, timestamp: .nan, isKeyframe: false, payload: syntheticBody).serialized()
require(!success(exchange(socket(frame: nan)).0), "비정상 timestamp 거절")
let huge = StreamMessage(kind: .pairResult, timestamp: 1, isKeyframe: false, payload: Data(repeating: 0, count: 4097)).serialized()
require(!success(exchange(socket(frame: huge)).0), "payload 상한 거절")
require(!success(exchange(socket(body: Data([1]))).0), "잘린 body 거절")
require(!success(exchange(socket(ended: true)).0), "header에서 종료 거절")
let failedSend = socket(); failedSend.sendError = true
require(!success(exchange(failedSend).0), "송신 오류 거절")
let cancelledBeforeSend = socket(); _ = exchange(cancelledBeforeSend, beforeStartCancel: true)
require(cancelledBeforeSend.sent.isEmpty && cancelledBeforeSend.cancelled, "취소 후 송신 0")
let waiting = NWConnection()
let waitingExchange = IPadOwnerReceiptExchange(connection: waiting, pin: Data(repeating: 7, count: 32), request: Data([1]), queue: socketQueue)
var finishedCount = 0
waitingExchange.start { _ in finishedCount += 1 }; socketQueue.sync {}
waitingExchange.cancel(); socketQueue.sync {}
socketQueue.sync { waiting.parked?(syntheticBody, nil, false, nil) }
require(finishedCount == 1 && waiting.sent.count == 1 && waiting.cancelled, "취소 뒤 늦은 socket callback 수용 0")

var keychainItem: [String: Any]?
var atomicRace = false
var corruptAfterWrite = false
func memoryCopyMatching(_ query: CFDictionary, _ found: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    guard let keychainItem else { return errSecItemNotFound }
    found?.pointee = keychainItem as CFDictionary; return errSecSuccess
}
func memoryAdd(_ attributes: CFDictionary, _ found: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    guard keychainItem == nil else { return errSecDuplicateItem }
    keychainItem = attributes as NSDictionary as? [String: Any]
    return errSecSuccess
}
func memoryUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    let match = query as NSDictionary as! [String: Any]
    let next = attributes as NSDictionary as! [String: Any]
    if atomicRace { keychainItem?[kSecAttrGeneric as String] = Data([1]); atomicRace = false }
    guard let item = keychainItem, let expected = match[kSecAttrGeneric as String] as? Data,
          item[kSecAttrGeneric as String] as? Data == expected else { return errSecItemNotFound }
    for (key, value) in next { keychainItem?[key] = value }
    if corruptAfterWrite { keychainItem?[kSecValueData as String] = Data("corrupt".utf8) }
    return errSecSuccess
}
let keychain = IPadEnrollmentStore(deviceID: String(repeating: "0", count: 64))
require(try! keychain.load() == nil, "명확한 item-not-found만 빈 저장소")
try keychain.compareAndSwap(nil, Data("first".utf8))
require(try! keychain.load() == Data("first".utf8), "실제 adapter 읽기·쓰기·readback")
require((keychainItem?[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String), "ThisDeviceOnly")
require((keychainItem?[kSecAttrSynchronizable as String] as? Bool) == false, "동기화 자격 없음")
refuses("CAS 다른 원문 덮기 금지") { try keychain.compareAndSwap(nil, Data("second".utf8)) }
atomicRace = true
refuses("SecItemUpdate 조건부 digest CAS") { try keychain.compareAndSwap(Data("first".utf8), Data("second".utf8)) }
require(keychainItem?[kSecValueData as String] as? Data == Data("first".utf8), "경쟁 변경 원문 보존")
refuses("손상 digest load") { _ = try keychain.load() }
keychainItem?[kSecAttrGeneric as String] = IPadEnrollmentProtocol.hash(Data("first".utf8))
corruptAfterWrite = true
refuses("키체인 쓰기 후 손상 readback") { try keychain.compareAndSwap(Data("first".utf8), Data("second".utf8)) }
require(keychainItem?[kSecValueData as String] as? Data == Data("corrupt".utf8), "손상 상태 임의 초기화 없음")
print("실제 socket/store adapter 메모리 검사 \(adapterChecks)개 통과. 실제 socket·Keychain 호출 0.")
