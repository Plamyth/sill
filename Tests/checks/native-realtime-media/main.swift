import Foundation
import StreamProtocol
import CryptoKit

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard value() else { fatalError(message) }
}
func rejects(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError(message) } catch { checks += 1 }
}
func json(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
let ids = ["675e086f-9672-4f3f-a8d2-ff690ac6cae0", "01a13005-ff61-7780-b0e8-6dc171de1c9d",
           "a3c96a77-bf2a-4c10-9937-8096e843643e", "f016fd00-28c2-40d5-a800-cae99f8a73cc"]
func target(uppercase: Bool = false) -> [String: Any] {
    let row = ["ccr-codex-realtime-target-v1", "codex-app-server"] + ids.prefix(3).map { uppercase ? $0.uppercased() : $0 }
    let bytes = try! JSONSerialization.data(withJSONObject: row, options: [.withoutEscapingSlashes])
    return ["schema": row[0], "providerKind": row[1], "providerInstanceId": row[2],
            "threadId": row[3], "voiceSessionId": row[4],
            "targetHash": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
}
let media: [String: Any] = ["pairedDeviceId": String(repeating: "a", count: 64), "transportKind": "native",
    "clientConnectionId": ids[3], "intentGeneration": ids[0], "bindingEpoch": ids[1], "transportId": ids[2],
    "leaseRevision": "18446744073709551615", "audioEpoch": "0"]
func attachObject(_ t: [String: Any] = target(), _ m: [String: Any] = media) -> [String: Any] {
    ["schemaVersion": 1, "op": "provider.media.attach", "coreGeneration": ids[3], "target": t, "media": m]
}
func ackObject(_ t: [String: Any] = target(), _ m: [String: Any] = media) -> [String: Any] {
    ["schemaVersion": 1, "op": "provider.media.attached", "coreGeneration": ids[3],
     "binding": ["target": t, "providerInstanceId": t["providerInstanceId"]!,
                 "voiceSessionId": t["voiceSessionId"]!, "connectionId": "actual-core-connection"],
     "media": m, "realtimeSessionId": "ccr-current-session"]
}
func makeScope(_ t: [String: Any] = target(), _ m: [String: Any] = media) throws -> NativeRealtimeMediaScope {
    try .acceptAcknowledgement(json(ackObject(t, m)), for: NativeRealtimeMediaScope.decodeAttach(json(attachObject(t, m))))
}
let scope = try makeScope()
func header(samples: Int = 240, source: String = "7", event: String = "9", chunk: String = "12",
            offset: Int = 0, total: Int = 240, item: Any = NSNull()) -> [String: Any] {
    ["schemaVersion": 1, "kind": "output", "coreGeneration": scope.coreGeneration,
     "targetHash": scope.binding.target.targetHash, "voiceSessionId": scope.binding.voiceSessionId,
     "connectionId": scope.binding.connectionId, "media": media, "realtimeSessionId": scope.realtimeSessionId,
     "sourceSequence": source, "eventSequence": event, "chunkSequence": chunk,
     "chunkOffsetSamples": offset, "chunkSamplesTotal": total, "itemId": item,
     "format": ["encoding": "pcm_s16le", "sampleRate": 24_000, "numChannels": 1], "samplesPerChannel": samples]
}
func framed(_ header: Data, pcm: Data = Data(repeating: 0x19, count: 480)) -> Data {
    let body = 2 + header.count + pcm.count
    var value = Data([UInt8((body >> 24) & 255), UInt8((body >> 16) & 255), UInt8((body >> 8) & 255), UInt8(body & 255),
                      UInt8((header.count >> 8) & 255), UInt8(header.count & 255)])
    value.append(header); value.append(pcm); return value
}
func frame(_ h: [String: Any] = header(), pcm: Data = Data(repeating: 0x19, count: 480)) -> Data {
    framed(json(h), pcm: pcm)
}
func active() throws -> (NativeRealtimeMediaDecoder, NativeRealtimeMediaPacketizer) {
    let d = NativeRealtimeMediaDecoder(), p = NativeRealtimeMediaPacketizer()
    try d.activate(scope: scope); try p.activate(scope: scope); return (d, p)
}
func malformed(_ name: String, _ bytes: Data) {
    let d = NativeRealtimeMediaDecoder(); try! d.activate(scope: scope)
    rejects(name) { try d.feed(bytes) { _ in fatalError(name + " callback") }; try d.finish() }
    check(d.lifecycle == .retired && d.ownedBuffersAreZero, name + " retire/zero")
}

let decoder = NativeRealtimeMediaDecoder()
let packetizer = NativeRealtimeMediaPacketizer()
check(decoder.lifecycle == .inactive, "decoder는 inactive로 시작")
check(packetizer.lifecycle == .inactive, "packetizer는 inactive로 시작")
decoder.retire()
packetizer.retire()
check(decoder.lifecycle == .retired, "decoder 폐기는 terminal")
check(packetizer.lifecycle == .retired, "packetizer 폐기는 terminal")
rejects("retired decoder 재활성화 거절") { try decoder.activate(scope: scope) }
rejects("retired packetizer 재활성화 거절") { try packetizer.activate(scope: scope) }
check(scope.binding.connectionId == "actual-core-connection", "producer connection은 ACK에서 읽음")
check(scope.media.leaseRevision == "18446744073709551615", "media UInt64 원문 보존")
let httpScope = try makeScope(target(), media.merging(["transportKind": "http"]) { _, next in next })
check(httpScope.media.transportKind == .http, "기존 http만 허용")
rejects("relay값 금지") { _ = try makeScope(target(), media.merging(["transportKind": "relay"]) { _, next in next }) }
let attach = try NativeRealtimeMediaScope.decodeAttach(json(attachObject()))
for key in ["op", "coreGeneration", "binding", "media", "realtimeSessionId"] {
    var bad = ackObject(); bad[key] = key == "realtimeSessionId" ? "" : "foreign"
    rejects("ACK field " + key) { _ = try NativeRealtimeMediaScope.acceptAcknowledgement(json(bad), for: attach) }
}
for key in ["target", "providerInstanceId", "voiceSessionId", "connectionId"] {
    var bad = ackObject(), binding = bad["binding"] as! [String: Any]
    binding[key] = key == "target" ? target(uppercase: true) : ""
    bad["binding"] = binding
    rejects("binding field " + key) { _ = try NativeRealtimeMediaScope.acceptAcknowledgement(json(bad), for: attach) }
}
for key in media.keys {
    var changed = media; changed[key] = "foreign"
    rejects("media field " + key) { _ = try NativeRealtimeMediaScope.acceptAcknowledgement(json(ackObject(target(), changed)), for: attach) }
}
let upper = try makeScope(target(uppercase: true))
check(upper.binding.voiceSessionId == ids[2].uppercased(), "대문자 UUID 원문 보존")
var wrongCase = ackObject(); var wrongBinding = wrongCase["binding"] as! [String: Any]
wrongBinding["voiceSessionId"] = ids[2].uppercased(); wrongCase["binding"] = wrongBinding
rejects("hash 같아도 voice raw case 변조 거절") { _ = try NativeRealtimeMediaScope.acceptAcknowledgement(json(wrongCase), for: attach) }
var extraAttach = attachObject(); extraAttach["binding"] = [:]
rejects("attach에서 binding 추정 금지") { _ = try NativeRealtimeMediaScope.decodeAttach(json(extraAttach)) }
let duplicateAttach = Data(String(decoding: json(attachObject()), as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8)
rejects("attach strict duplicate") { _ = try NativeRealtimeMediaScope.decodeAttach(duplicateAttach) }

let bytes = frame()
for split in 0...bytes.count {
    let d = NativeRealtimeMediaDecoder(); try d.activate(scope: scope)
    var received = 0
    let consume: (NativeRealtimeMediaFrame) -> Void = { value in
        received += 1
        guard value.pcm.count == 480, value.pcm[0] == 0x19 else { fatalError("fragment PCM") }
    }
    try d.feed(bytes.prefix(split), consume: consume)
    try d.feed(bytes.dropFirst(split), consume: consume)
    check(received == 1 && d.ownedBuffersAreZero, "모든 byte 분할 경계")
    try d.finish()
}
do {
    let (d, p) = try active()
    try d.feed(frame(header(samples: 100, source: "7", event: "9", chunk: "12", offset: 0, total: 300, item: "item-a"),
                     pcm: Data(repeating: 0x01, count: 200))) { try p.offer($0) }
    let partial = try p.pull()
    check(partial == nil, "부분 10ms는 대기")
    try d.feed(frame(header(samples: 200, source: "7", event: "9", chunk: "12", offset: 100, total: 300, item: "item-a"),
                     pcm: Data(repeating: 0x02, count: 400))) { try p.offer($0) }
    let first = try p.pull()!
    check(first.nativePacketSequence == 1 && first.segments.count == 2, "별도 native packet 순번")
    check(first.segments.map(\.samples) == [100, 140], "원본 frame 경계 보존")
    check(first.segments.map(\.chunkOffsetSamples) == [0, 100], "원본 offset 보존")
    check(first.segments.allSatisfy { $0.output.sourceSequence == "7" && $0.output.eventSequence == "9" && $0.output.chunkSequence == "12" }, "원본 순번 재발급 없음")
    let decoded = AudioPacket.unpack(first.audioPacket)!
    check(decoded.sampleRate == 24_000 && decoded.channels == 1 && decoded.samples.count == 240, "기존 AudioPacket 10ms")
    check(decoded.samples[0] == 0x0101 && decoded.samples[100] == 0x0202, "borrowed storage 소거 후에도 bounded copy 유지")
    try d.feed(frame(header(samples: 180, source: "11", event: "15", chunk: "13", offset: 0, total: 180, item: "item-b"),
                     pcm: Data(repeating: 0x03, count: 360))) { try p.offer($0) }
    let second = try p.pull()!
    check(second.nativePacketSequence == 2 && second.segments.map(\.samples) == [60, 180], "chunk 사이 부분 packet 합성")
    check(second.segments.map(\.chunkOffsetSamples) == [240, 0], "chunk source 증가와 offset0")
    check(second.segments.map { $0.output.chunkSequence } == ["12", "13"], "chunk 원본 그대로")
    check(p.queuedPCMBytes == 0 && p.queuedFrames == 0 && p.ownedBuffersAreZero, "drain 후 PCM 소거")
    try d.finish(); p.retire(.endOfStream)
}
for badSequence in ["0", "-1", "+1", "01", "1.0", "1e2", "9007199254740992", "18446744073709551616", " 1", "١"] {
    for key in ["sourceSequence", "eventSequence", "chunkSequence"] {
        var h = header(); h[key] = badSequence
        malformed("canonical " + key + " " + badSequence, frame(h))
    }
}
for mutation: [String: Any] in [
    ["sourceSequence": 7], ["schemaVersion": true], ["samplesPerChannel": true], ["samplesPerChannel": 0],
    ["samplesPerChannel": 241], ["chunkOffsetSamples": -1], ["chunkOffsetSamples": 1],
    ["chunkSamplesTotal": 240001], ["chunkSamplesTotal": 239], ["kind": "control"], ["extra": 1],
    ["format": ["encoding": "pcm_s16le", "sampleRate": 48000, "numChannels": 1]],
    ["format": ["encoding": "pcm_s16be", "sampleRate": 24000, "numChannels": 1]],
    ["format": ["encoding": "pcm_s16le", "sampleRate": 24000, "numChannels": 2]],
    ["format": ["encoding": "pcm_s16le", "sampleRate": 24000, "numChannels": 1, "extra": 0]],
    ["voiceSessionId": ids[2].uppercased()], ["connectionId": "foreign"], ["coreGeneration": ids[3].uppercased()],
    ["realtimeSessionId": "other"], ["targetHash": String(repeating: "0", count: 64)],
    ["media": media.merging(["clientConnectionId": ids[3].uppercased()]) { _, next in next }],
    ["itemId": String(repeating: "a", count: 129)], ["itemId": [:]]
] {
    malformed("잘못된 header 거절", frame(header().merging(mutation) { _, next in next }))
}
malformed("empty PCM", frame(pcm: Data()))
malformed("odd PCM", frame(pcm: Data(repeating: 1, count: 479)))
malformed("over PCM", frame(pcm: Data(repeating: 1, count: 482)))
malformed("body overflow", Data([255,255,255,255]))
malformed("body zero", Data([0,0,0,0]))
malformed("header over 4096", Data([0,0,17,0,16,1]))
malformed("header exceeds body", Data([0,0,0,4,0,8]))
malformed("truncated prefix", Data([0,0,0]))
malformed("truncated PCM", bytes.dropLast())
var raw = String(decoding: json(header()), as: UTF8.self)
raw = raw.replacingOccurrences(of: "\"kind\":\"output\"", with: "\"kind\":\"output\",\"k\\u0069nd\":\"output\"")
malformed("escaped duplicate", framed(Data(raw.utf8)))
raw = String(decoding: json(header()), as: UTF8.self).replacingOccurrences(of: "\"numChannels\":1", with: "\"numChannels\":1,\"numChannels\":1")
malformed("nested duplicate", framed(Data(raw.utf8)))
var invalidUTF8 = json(header()); invalidUTF8[20] = 0xFF
malformed("invalid UTF8", framed(invalidUTF8))
malformed("BOM", framed(Data([0xEF,0xBB,0xBF]) + json(header())))
malformed("extra JSON bytes", framed(json(header()) + Data("{}".utf8)))
do {
    let d = NativeRealtimeMediaDecoder(); try d.activate(scope: scope)
    try d.feed(frame(header(total: 480))) { _ in }
    rejects("EOF가 원본 chunk 중간") { try d.finish() }
    check(d.ownedBuffersAreZero, "미완 chunk EOF 소거")
}
for changed: [String: Any] in [["sourceSequence": "8"], ["eventSequence": "10"], ["itemId": "changed"],
                              ["chunkSamplesTotal": 481], ["chunkOffsetSamples": 239], ["chunkOffsetSamples": 241],
                              ["chunkSequence": "13"], ["chunkSequence": "11"]] {
    let (d, p) = try active()
    try d.feed(frame(header(total: 480))) { try p.offer($0) }
    let h = header(offset: 240, total: 480).merging(changed) { _, next in next }
    rejects("same chunk metadata/continuity") { try d.feed(frame(h)) { try p.offer($0) } }
    p.retire()
    check(d.lifecycle == .retired && d.ownedBuffersAreZero && p.ownedBuffersAreZero, "gap 소거")
}
for h in [header(source: "7", event: "10", chunk: "13"), header(source: "8", event: "9", chunk: "13"),
          header(source: "8", event: "10", chunk: "14"), header(source: "8", event: "10", chunk: "11"), header()] {
    let (d, p) = try active()
    try d.feed(frame()) { try p.offer($0) }
    rejects("다음chunk gap/중복/역순") { try d.feed(frame(h)) { try p.offer($0) } }
    p.retire(); check(p.ownedBuffersAreZero && d.ownedBuffersAreZero, "다음chunk 실패 소거")
}
do {
    let (d, p) = try active()
    try d.feed(frame()) { value in
        try p.offer(value)
        rejects("동일 borrowed frame 재제공 거절") { try p.offer(value) }
    }
    check(p.lifecycle == .retired && p.ownedBuffersAreZero && p.queuedFrames == 0, "packetizer duplicate zero")
}
do {
    let (d, p) = try active()
    try d.feed(frame(header(samples: 1, total: 1), pcm: Data([1,2]))) { try p.offer($0) }
    p.retire(); d.retire()
    check(p.queuedPCMBytes == 0 && p.ownedBuffersAreZero && d.ownedBuffersAreZero, "reset의 부분 PCM 폐기")
    rejects("retired scope 재활성화 안 함") { try p.activate(scope: scope) }
    let fresh = NativeRealtimeMediaDecoder(); try fresh.activate(scope: upper)
    rejects("foreign callback으로 새 scope 복구 안 함") { try fresh.feed(frame()) { _ in } }
    rejects("foreign 후 재활성화 안 함") { try fresh.activate(scope: upper) }
    check(fresh.ownedBuffersAreZero, "foreign 소거")
}
do {
    let (d, _) = try active()
    rejects("재진입 feed") {
        try d.feed(frame()) { _ in
            rejects("nested rejection") { try d.feed(Data()) { _ in } }
        }
    }
    check(d.lifecycle == .retired && d.ownedBuffersAreZero, "재진입 retire/zero")
}
do {
    let (d, _) = try active()
    rejects("throwing consumer") { try d.feed(frame()) { _ in throw NativeRealtimeMediaFailure.consumerRejected } }
    check(d.lifecycle == .retired && d.ownedBuffersAreZero, "consumer throw zero")
}
do {
    let (d, p) = try active()
    for index in 0..<1000 {
        try d.feed(frame(header(chunk: "100", offset: index * 240, total: 240000))) { try p.offer($0) }
    }
    check(p.queuedPCMBytes == 480000 && p.queuedFrames == 1000, "정확10s 원본 한도 수용")
    rejects("큐 PCM 상한 초과") {
        try d.feed(frame(header(source: "8", event: "10", chunk: "101"))) { try p.offer($0) }
    }
    check(p.lifecycle == .retired && p.queuedPCMBytes == 0 && p.ownedBuffersAreZero, "큐 초과 retire zero")
}
do {
    let (d, p) = try active()
    for index in 0..<NativeRealtimeMediaPacketizer.maximumPendingFrames {
        try d.feed(frame(header(samples: 1, chunk: "3", offset: index, total: 240000), pcm: Data([1,2]))) { try p.offer($0) }
    }
    rejects("metadata 유한 상한") {
        try d.feed(frame(header(samples: 1, chunk: "3", offset: 2000, total: 240000), pcm: Data([1,2]))) { try p.offer($0) }
    }
    check(p.lifecycle == .retired && p.ownedBuffersAreZero && p.queuedFrames == 0, "metadata 초과 소거")
}
do {
    let (d, p) = try active()
    let pcm = Data([0x00,0x80,0xFF,0x7F] + [UInt8](repeating: 0, count: 476))
    try d.feed(frame(header(source: "9007199254740991", event: "9007199254740991", chunk: "9007199254740991"), pcm: pcm)) { try p.offer($0) }
    let packet = try p.pull()!
    check(AudioPacket.unpack(packet.audioPacket)!.samples.prefix(2) == [-32768,32767], "PCM16LE 부호/최대 순번")
    rejects("최대chunk 다음overflow") { try d.feed(frame(header(chunk: "9007199254740992"))) { _ in } }
}
do {
    let d = NativeRealtimeMediaDecoder(); try d.activate(scope: scope)
    let ready = try NativeRealtimeMediaCodec.ready(scope: scope)
    var kinds = 0
    try d.feed(ready) { if case .ready = $0.header.payload { kinds += 1 } }
    var pcm = Data(repeating: 0x12, count: 480)
    let input = try pcm.withUnsafeBytes { try NativeRealtimeMediaCodec.input(scope: scope, sequence: "1", itemId: nil, pcm: $0) }
    pcm.resetBytes(in: 0..<pcm.count)
    try d.feed(input) { if case .input(let seq, let item) = $0.header.payload { check(seq == "1" && item == nil && $0.pcm[0] == 0x12, "입력typedmodel"); kinds += 1 } }
    check(kinds == 2, "ready/input models")
    rejects("input 중복") { try d.feed(input) { _ in } }
    check(d.ownedBuffersAreZero, "input 중복 소거")
}
do {
    let d = NativeRealtimeMediaDecoder(); try d.activate(scope: scope)
    let ready = try NativeRealtimeMediaCodec.ready(scope: scope)
    try d.feed(ready) { _ in }
    rejects("ready 중복") { try d.feed(ready) { _ in } }
    rejects("초과 input encoding") { try Data(repeating: 0, count: 482).withUnsafeBytes { _ = try NativeRealtimeMediaCodec.input(scope: scope, sequence: "1", itemId: nil, pcm: $0) } }
}
do {
    let (d, p) = try active()
    var maximumHeader = json(header())
    maximumHeader.append(Data(repeating: 32, count: 4096 - maximumHeader.count))
    let maximumFrame = framed(maximumHeader)
    check(maximumFrame.count == 4582, "body4578 정확 상한")
    try d.feed(maximumFrame) { try p.offer($0) }
    check(try! p.pull() != nil, "4096 header 정확 상한 수용")
}
do {
    let (d, p) = try active()
    var joined = frame()
    joined.append(frame(header(source: "10", event: "20", chunk: "13")))
    try d.feed(joined) { try p.offer($0) }
    check(p.queuedPCMBytes == 960, "coalesced frames 두개 수용")
    let first = try p.pull(), second = try p.pull()
    check(first?.nativePacketSequence == 1 && second?.nativePacketSequence == 2, "coalesced 순번")
}
do {
    let (d, p) = try active()
    var failure: NativeRealtimeMediaFailure?
    for index in 0..<241 {
        do {
            try d.feed(frame(header(samples: 1, source: String(index + 1), event: String(index + 1), chunk: String(index + 1), total: 1), pcm: Data([1,2]))) { try p.offer($0) }
        } catch { failure = error as? NativeRealtimeMediaFailure }
    }
    check(failure == nil, "한 sample chunk도 유한 metadata로 처리")
    let packet = try p.pull()!
    check(packet.segments.count == 240 && packet.segments.map(\.samples).allSatisfy { $0 == 1 }, "packet segment도 최대240개")
    check(p.queuedPCMBytes == 2 && p.queuedFrames == 1, "다음 packet 부분 metadata만 잔류")
    p.retire()
    check(p.ownedBuffersAreZero && p.queuedFrames == 0, "한 sample 부분도 폐기")
}
do {
    let (d, p) = try active()
    let other = NativeRealtimeMediaDecoder(); try other.activate(scope: upper)
    let encoded = try Data([1,0]).withUnsafeBytes {
        try NativeRealtimeMediaCodec.input(scope: upper, sequence: "1", itemId: "input-only", pcm: $0)
    }
    rejects("packetizer foreign scope") { try other.feed(encoded) { try p.offer($0) } }
    check(p.lifecycle == .retired && p.ownedBuffersAreZero && other.ownedBuffersAreZero, "foreign scope 양쪽 소거")
    d.retire()
}
do {
    let d = NativeRealtimeMediaDecoder(); try d.activate(scope: scope)
    let encoded = try Data([1,0]).withUnsafeBytes { try NativeRealtimeMediaCodec.input(scope: scope, sequence: "2", itemId: nil, pcm: $0) }
    rejects("input 첫순번 gap") { try d.feed(encoded) { _ in } }
    check(d.ownedBuffersAreZero && d.lifecycle == .retired, "input gap 소거")
}
rejects("ACK와 binary 혼합 금지") {
    _ = try NativeRealtimeMediaScope.acceptAcknowledgement(json(ackObject()) + frame(), for: attach)
}
rejects("확정되지 않은 아홉번째 media키 금지") {
    _ = try makeScope(target(), media.merging(["unknownAuthority": "invented"]) { _, next in next })
}
print("NATIVE_MEDIA_MODEL passed \(checks) checks")
