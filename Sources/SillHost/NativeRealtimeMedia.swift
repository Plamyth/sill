import Foundation
import CoreFoundation
import Darwin
import StreamProtocol

enum NativeRealtimeMediaFailure: Error, Equatable {
    case invalidFields, invalidScope, invalidSequence, invalidPCM, invalidLength
    case inactive, retired, reentrant, queueFull, consumerRejected, truncated
}

enum NativeRealtimeMediaLifecycle { case inactive, current, retired }

private enum MediaJSON {
    static func object(_ data: Data, limit: Int) throws -> [String: Any] {
        guard data.count <= limit else { throw NativeRealtimeMediaFailure.invalidLength }
        try LocalAudioRelayJSON.validate(data)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeRealtimeMediaFailure.invalidFields
        }
        return value
    }
    static func exact(_ object: [String: Any], _ keys: [String]) throws {
        guard Set(object.keys) == Set(keys) else { throw NativeRealtimeMediaFailure.invalidFields }
    }
    static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw NativeRealtimeMediaFailure.invalidFields }
        return value
    }
    static func identifier(_ value: String) throws -> String {
        guard value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
            throw NativeRealtimeMediaFailure.invalidScope
        }
        return value
    }
    static func uuid(_ value: String) throws -> String {
        guard value.utf8.count == 36, UUID(uuidString: value) != nil else {
            throw NativeRealtimeMediaFailure.invalidScope
        }
        return value
    }
    static func decimal(_ value: String, maximum: UInt64 = .max, positive: Bool = false) throws -> UInt64 {
        guard let number = UInt64(value), String(number) == value, number <= maximum,
              !positive || number > 0 else { throw NativeRealtimeMediaFailure.invalidSequence }
        return number
    }
    static func integer(_ object: [String: Any], _ key: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else {
            throw NativeRealtimeMediaFailure.invalidFields
        }
        return number.intValue
    }
    static func child(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw NativeRealtimeMediaFailure.invalidFields }
        return value
    }
    static func target(_ object: [String: Any]) throws -> CodexRealtimeTarget {
        try JSONDecoder().decode(CodexRealtimeTarget.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// Syntactic context only. The caller must independently check auth, current subscriber and lease.
struct NativeRealtimeMediaScope: Equatable {
    struct Media: Equatable {
        let pairedDeviceId: String
        let transportKind: AudioForwardingTransport
        let clientConnectionId: String
        let intentGeneration: String
        let bindingEpoch: String
        let transportId: String
        let leaseRevision: String
        let audioEpoch: String

        fileprivate init(_ object: [String: Any]) throws {
            try MediaJSON.exact(object, ["pairedDeviceId", "transportKind", "clientConnectionId",
                "intentGeneration", "bindingEpoch", "transportId", "leaseRevision", "audioEpoch"])
            pairedDeviceId = try MediaJSON.text(object, "pairedDeviceId")
            guard AudioForwardingDeviceID(hex: pairedDeviceId) != nil,
                  let transport = AudioForwardingTransport(rawValue: try MediaJSON.text(object, "transportKind")) else {
                throw NativeRealtimeMediaFailure.invalidScope
            }
            transportKind = transport
            clientConnectionId = try MediaJSON.uuid(MediaJSON.text(object, "clientConnectionId"))
            intentGeneration = try MediaJSON.uuid(MediaJSON.text(object, "intentGeneration"))
            bindingEpoch = try MediaJSON.uuid(MediaJSON.text(object, "bindingEpoch"))
            transportId = try MediaJSON.uuid(MediaJSON.text(object, "transportId"))
            leaseRevision = try MediaJSON.text(object, "leaseRevision")
            audioEpoch = try MediaJSON.text(object, "audioEpoch")
            _ = try MediaJSON.decimal(leaseRevision)
            _ = try MediaJSON.decimal(audioEpoch)
        }
        fileprivate var object: [String: Any] {
            ["pairedDeviceId": pairedDeviceId, "transportKind": transportKind.rawValue,
             "clientConnectionId": clientConnectionId, "intentGeneration": intentGeneration,
             "bindingEpoch": bindingEpoch, "transportId": transportId,
             "leaseRevision": leaseRevision, "audioEpoch": audioEpoch]
        }
    }
    struct Attach {
        let coreGeneration: String
        let target: CodexRealtimeTarget
        let media: Media
        fileprivate init(coreGeneration: String, target: CodexRealtimeTarget, media: Media) {
            self.coreGeneration = coreGeneration; self.target = target; self.media = media
        }
    }
    struct Binding: Equatable {
        let target: CodexRealtimeTarget
        let providerInstanceId: String
        let voiceSessionId: String
        let connectionId: String
        fileprivate init(_ object: [String: Any], target expected: CodexRealtimeTarget) throws {
            try MediaJSON.exact(object, ["target", "providerInstanceId", "voiceSessionId", "connectionId"])
            target = try MediaJSON.target(MediaJSON.child(object, "target"))
            providerInstanceId = try MediaJSON.text(object, "providerInstanceId")
            voiceSessionId = try MediaJSON.text(object, "voiceSessionId")
            connectionId = try MediaJSON.identifier(MediaJSON.text(object, "connectionId"))
            guard target == expected, providerInstanceId == expected.providerInstanceId,
                  voiceSessionId == expected.voiceSessionId else { throw NativeRealtimeMediaFailure.invalidScope }
        }
    }
    let coreGeneration: String
    let binding: Binding
    let media: Media
    let realtimeSessionId: String

    private init(coreGeneration: String, binding: Binding, media: Media, realtimeSessionId: String) {
        self.coreGeneration = coreGeneration; self.binding = binding
        self.media = media; self.realtimeSessionId = realtimeSessionId
    }

    static func decodeAttach(_ data: Data) throws -> Attach {
        let object = try MediaJSON.object(data, limit: LocalAudioRelayJSON.limit - 1)
        try MediaJSON.exact(object, ["schemaVersion", "op", "coreGeneration", "target", "media"])
        guard try MediaJSON.integer(object, "schemaVersion", 1...1) == 1,
              try MediaJSON.text(object, "op") == "provider.media.attach" else {
            throw NativeRealtimeMediaFailure.invalidFields
        }
        return try Attach(coreGeneration: MediaJSON.uuid(MediaJSON.text(object, "coreGeneration")),
            target: MediaJSON.target(MediaJSON.child(object, "target")), media: Media(MediaJSON.child(object, "media")))
    }

    static func acceptAcknowledgement(_ data: Data, for attach: Attach) throws -> Self {
        let object = try MediaJSON.object(data, limit: LocalAudioRelayJSON.limit - 1)
        try MediaJSON.exact(object, ["schemaVersion", "op", "coreGeneration", "binding", "media", "realtimeSessionId"])
        guard try MediaJSON.integer(object, "schemaVersion", 1...1) == 1,
              try MediaJSON.text(object, "op") == "provider.media.attached",
              try MediaJSON.text(object, "coreGeneration") == attach.coreGeneration else {
            throw NativeRealtimeMediaFailure.invalidScope
        }
        let media = try Media(MediaJSON.child(object, "media"))
        guard media == attach.media else { throw NativeRealtimeMediaFailure.invalidScope }
        return try Self(coreGeneration: attach.coreGeneration,
            binding: Binding(MediaJSON.child(object, "binding"), target: attach.target), media: media,
            realtimeSessionId: MediaJSON.identifier(MediaJSON.text(object, "realtimeSessionId")))
    }

    fileprivate var context: [String: Any] {
        ["schemaVersion": 1, "coreGeneration": coreGeneration, "targetHash": binding.target.targetHash,
         "voiceSessionId": binding.voiceSessionId, "connectionId": binding.connectionId,
         "media": media.object, "realtimeSessionId": realtimeSessionId]
    }
    fileprivate func matches(_ object: [String: Any]) throws -> Bool {
        try MediaJSON.integer(object, "schemaVersion", 1...1) == 1 &&
        MediaJSON.text(object, "coreGeneration") == coreGeneration &&
        MediaJSON.text(object, "targetHash") == binding.target.targetHash &&
        MediaJSON.text(object, "voiceSessionId") == binding.voiceSessionId &&
        MediaJSON.text(object, "connectionId") == binding.connectionId &&
        MediaJSON.text(object, "realtimeSessionId") == realtimeSessionId &&
        Media(MediaJSON.child(object, "media")) == media
    }
}

struct NativeRealtimeMediaOutput: Equatable {
    let sourceSequence: String
    let eventSequence: String
    let chunkSequence: String
    let chunkOffsetSamples: Int
    let chunkSamplesTotal: Int
    let itemId: String?
    fileprivate let source: UInt64
    fileprivate let event: UInt64
    fileprivate let chunk: UInt64

    fileprivate init(_ object: [String: Any]) throws {
        sourceSequence = try MediaJSON.text(object, "sourceSequence")
        eventSequence = try MediaJSON.text(object, "eventSequence")
        chunkSequence = try MediaJSON.text(object, "chunkSequence")
        source = try MediaJSON.decimal(sourceSequence, maximum: NativeRealtimeMediaCodec.maximumSequence, positive: true)
        event = try MediaJSON.decimal(eventSequence, maximum: NativeRealtimeMediaCodec.maximumSequence, positive: true)
        chunk = try MediaJSON.decimal(chunkSequence, maximum: NativeRealtimeMediaCodec.maximumSequence, positive: true)
        chunkOffsetSamples = try MediaJSON.integer(object, "chunkOffsetSamples", 0...239_999)
        chunkSamplesTotal = try MediaJSON.integer(object, "chunkSamplesTotal", 1...240_000)
        itemId = try NativeRealtimeMediaCodec.item(object)
    }
}

struct NativeRealtimeMediaHeader {
    enum Payload {
        case ready
        case input(sequence: String, itemId: String?)
        case output(NativeRealtimeMediaOutput)
    }
    let scope: NativeRealtimeMediaScope
    let payload: Payload
    let samplesPerChannel: Int
    fileprivate init(_ bytes: Data, pcmBytes: Int, scope: NativeRealtimeMediaScope) throws {
        let object = try MediaJSON.object(bytes, limit: NativeRealtimeMediaCodec.maximumHeaderBytes)
        guard try scope.matches(object) else { throw NativeRealtimeMediaFailure.invalidScope }
        self.scope = scope
        let common = Array(scope.context.keys) + ["kind"]
        switch try MediaJSON.text(object, "kind") {
        case "ready":
            try MediaJSON.exact(object, common)
            guard pcmBytes == 0 else { throw NativeRealtimeMediaFailure.invalidPCM }
            payload = .ready; samplesPerChannel = 0
        case "input", "output":
            let kind = try MediaJSON.text(object, "kind")
            try MediaJSON.exact(object, common + ["format", "samplesPerChannel", "itemId"] +
                (kind == "input" ? ["inputSequence"] : ["sourceSequence", "eventSequence", "chunkSequence",
                    "chunkOffsetSamples", "chunkSamplesTotal"]))
            let format = try MediaJSON.child(object, "format")
            try MediaJSON.exact(format, ["encoding", "sampleRate", "numChannels"])
            guard try MediaJSON.text(format, "encoding") == "pcm_s16le",
                  try MediaJSON.integer(format, "sampleRate", 24_000...24_000) == 24_000,
                  try MediaJSON.integer(format, "numChannels", 1...1) == 1 else {
                throw NativeRealtimeMediaFailure.invalidPCM
            }
            samplesPerChannel = try MediaJSON.integer(object, "samplesPerChannel", 1...240)
            guard pcmBytes == samplesPerChannel * 2 else { throw NativeRealtimeMediaFailure.invalidPCM }
            if kind == "input" {
                let sequence = try MediaJSON.text(object, "inputSequence")
                _ = try MediaJSON.decimal(sequence, maximum: NativeRealtimeMediaCodec.maximumSequence, positive: true)
                payload = .input(sequence: sequence, itemId: try NativeRealtimeMediaCodec.item(object))
            } else {
                let output = try NativeRealtimeMediaOutput(object)
                guard samplesPerChannel <= output.chunkSamplesTotal - output.chunkOffsetSamples else {
                    throw NativeRealtimeMediaFailure.invalidPCM
                }
                payload = .output(output)
            }
        default: throw NativeRealtimeMediaFailure.invalidFields
        }
    }
}

/// The PCM pointer is borrowed until the synchronous feed callback returns. Never retain it.
/// offer(frame) makes a bounded copy. Any other escaping consumer must do the same before returning.
struct NativeRealtimeMediaFrame {
    let header: NativeRealtimeMediaHeader
    let pcm: UnsafeRawBufferPointer
    fileprivate init(header: NativeRealtimeMediaHeader, pcm: UnsafeRawBufferPointer) {
        self.header = header; self.pcm = pcm
    }
}

enum NativeRealtimeMediaControl { case endOfStream, scopeLost }

enum NativeRealtimeMediaCodec {
    static let maximumSequence: UInt64 = 9_007_199_254_740_991
    static let maximumHeaderBytes = 4096
    static let maximumPCMBytes = 480
    static let maximumBodyBytes = 4578
    static let format: [String: Any] = ["encoding": "pcm_s16le", "sampleRate": 24_000, "numChannels": 1]

    fileprivate static func item(_ object: [String: Any]) throws -> String? {
        if object["itemId"] is NSNull { return nil }
        return try MediaJSON.identifier(MediaJSON.text(object, "itemId"))
    }
    static func ready(scope: NativeRealtimeMediaScope) throws -> Data {
        var header = scope.context; header["kind"] = "ready"
        return try encode(header, pcm: UnsafeRawBufferPointer(start: nil, count: 0), scope: scope)
    }
    /// Ownership of returned bytes transfers to the caller, including clearing after transport use.
    static func input(scope: NativeRealtimeMediaScope, sequence: String, itemId: String?,
                      pcm: UnsafeRawBufferPointer) throws -> Data {
        guard pcm.count > 0, pcm.count <= maximumPCMBytes, pcm.count % 2 == 0 else {
            throw NativeRealtimeMediaFailure.invalidPCM
        }
        var header = scope.context
        header["kind"] = "input"; header["inputSequence"] = sequence
        header["format"] = format; header["samplesPerChannel"] = pcm.count / 2
        header["itemId"] = itemId as Any? ?? NSNull()
        return try encode(header, pcm: pcm, scope: scope)
    }
    private static func encode(_ object: [String: Any], pcm: UnsafeRawBufferPointer,
                               scope: NativeRealtimeMediaScope) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try NativeRealtimeMediaHeader(bytes, pcmBytes: pcm.count, scope: scope)
        var result = Data(capacity: 6 + bytes.count + pcm.count)
        var bodyLength = UInt32(2 + bytes.count + pcm.count).bigEndian
        var headerLength = UInt16(bytes.count).bigEndian
        withUnsafeBytes(of: &bodyLength) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &headerLength) { result.append(contentsOf: $0) }
        result.append(bytes)
        result.append(contentsOf: pcm)
        return result
    }
}

private struct MediaOutputCursor {
    let output: NativeRealtimeMediaOutput
    let nextOffset: Int
    static func advance(_ previous: Self?, _ output: NativeRealtimeMediaOutput, samples: Int) throws -> Self {
        if let previous {
            let last = previous.output
            if output.chunk == last.chunk {
                guard output.sourceSequence == last.sourceSequence, output.eventSequence == last.eventSequence,
                      output.itemId == last.itemId, output.chunkSamplesTotal == last.chunkSamplesTotal,
                      output.chunkOffsetSamples == previous.nextOffset else {
                    throw NativeRealtimeMediaFailure.invalidSequence
                }
            } else {
                guard previous.nextOffset == last.chunkSamplesTotal, output.chunk == last.chunk + 1,
                      output.source > last.source, output.event > last.event, output.chunkOffsetSamples == 0 else {
                    throw NativeRealtimeMediaFailure.invalidSequence
                }
            }
        } else if output.chunkOffsetSamples != 0 { throw NativeRealtimeMediaFailure.invalidSequence }
        return Self(output: output, nextOffset: output.chunkOffsetSamples + samples)
    }
}

/// One instance owns one attachment. Scope replacement requires a fresh instance, never resurrection.
final class NativeRealtimeMediaDecoder {
    private let lock = NSRecursiveLock()
    private var busy = false
    private var phase = NativeRealtimeMediaLifecycle.inactive
    private var scope: NativeRealtimeMediaScope?
    private let storage = UnsafeMutableRawPointer.allocate(byteCount: 4582, alignment: 8)
    private var count = 0
    private var expected = 4
    private var headerBytes = 0
    private var outputCursor: MediaOutputCursor?
    private var inputSequence: UInt64 = 0
    private var readySeen = false

    init() { wipe() }
    deinit { wipe(); storage.deallocate() }
    var lifecycle: NativeRealtimeMediaLifecycle { lock.withLock { phase } }
    var ownedBuffersAreZero: Bool { lock.withLock { (0..<4582).allSatisfy { storage.load(fromByteOffset: $0, as: UInt8.self) == 0 } } }

    func activate(scope: NativeRealtimeMediaScope) throws {
        try operation {
            guard phase == .inactive else { throw NativeRealtimeMediaFailure.retired }
            self.scope = scope; phase = .current
        }
    }
    func retire(_ control: NativeRealtimeMediaControl = .scopeLost) {
        lock.withLock { retireOwned() }
    }
    func finish() throws {
        try operation {
            guard phase == .current else { throw NativeRealtimeMediaFailure.retired }
            guard count == 0, outputCursor.map({ $0.nextOffset == $0.output.chunkSamplesTotal }) ?? true else {
                throw NativeRealtimeMediaFailure.truncated
            }
            retireOwned()
        }
    }
    func feed(_ bytes: Data, consume: (NativeRealtimeMediaFrame) throws -> Void) throws {
        try bytes.withUnsafeBytes { try feed($0, consume: consume) }
    }
    func feed(_ bytes: UnsafeRawBufferPointer, consume: (NativeRealtimeMediaFrame) throws -> Void) throws {
        try operation {
            guard phase == .current, let scope else { throw NativeRealtimeMediaFailure.inactive }
            var offset = 0
            while offset < bytes.count {
                guard phase == .current else { throw NativeRealtimeMediaFailure.retired }
                let copied = min(expected - count, bytes.count - offset)
                if copied > 0 {
                    storage.advanced(by: count).copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: copied)
                    count += copied; offset += copied
                }
                guard count == expected else { continue }
                if expected == 4 {
                    let body = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(storage.load(fromByteOffset: $1, as: UInt8.self)) }
                    guard body >= 3, body <= NativeRealtimeMediaCodec.maximumBodyBytes else {
                        throw NativeRealtimeMediaFailure.invalidLength
                    }
                    expected = 6; continue
                }
                if headerBytes == 0 {
                    headerBytes = Int(storage.load(fromByteOffset: 4, as: UInt8.self)) * 256 + Int(storage.load(fromByteOffset: 5, as: UInt8.self))
                    let body = (0..<4).reduce(0) { ($0 << 8) | Int(storage.load(fromByteOffset: $1, as: UInt8.self)) }
                    let pcmBytes = body - 2 - headerBytes
                    guard (1...4096).contains(headerBytes), (0...480).contains(pcmBytes), pcmBytes % 2 == 0 else {
                        throw NativeRealtimeMediaFailure.invalidLength
                    }
                    expected = body + 4
                    if count < expected { continue }
                }
                let pcmBytes = count - 6 - headerBytes
                let header = try NativeRealtimeMediaHeader(Data(bytes: storage.advanced(by: 6), count: headerBytes),
                    pcmBytes: pcmBytes, scope: scope)
                switch header.payload {
                case .ready:
                    guard !readySeen else { throw NativeRealtimeMediaFailure.invalidSequence }; readySeen = true
                case .input(let sequence, _):
                    guard let next = UInt64(sequence), next == inputSequence + 1 else { throw NativeRealtimeMediaFailure.invalidSequence }
                    inputSequence = next
                case .output(let output):
                    outputCursor = try MediaOutputCursor.advance(outputCursor, output, samples: header.samplesPerChannel)
                }
                do {
                    try consume(NativeRealtimeMediaFrame(header: header,
                        pcm: UnsafeRawBufferPointer(start: storage.advanced(by: 6 + headerBytes), count: pcmBytes)))
                } catch { throw NativeRealtimeMediaFailure.consumerRejected }
                guard phase == .current else { throw NativeRealtimeMediaFailure.retired }
                wipe(); count = 0; expected = 4; headerBytes = 0
            }
        }
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !busy else { retireOwned(); throw NativeRealtimeMediaFailure.reentrant }
            busy = true; defer { busy = false }
            do { return try body() } catch { retireOwned(); throw error }
        }
    }
    private func wipe() { _ = memset_s(storage, 4582, 0, 4582) }
    private func retireOwned() {
        wipe(); count = 0; expected = 4; headerBytes = 0
        outputCursor = nil; inputSequence = 0; readySeen = false; scope = nil; phase = .retired
    }
}

final class NativeRealtimeMediaPacketizer {
    struct Segment {
        let output: NativeRealtimeMediaOutput
        let offsetInFrame: Int
        let samples: Int
        var chunkOffsetSamples: Int { output.chunkOffsetSamples + offsetInFrame }
    }
    struct Packet {
        let scope: NativeRealtimeMediaScope
        let nativePacketSequence: UInt64
        let audioPacket: Data
        let segments: [Segment]
    }
    private struct Pending {
        let output: NativeRealtimeMediaOutput
        let samples: Int
        var consumed: Int
    }
    static let maximumPCMBytes = 480_000
    static let maximumPendingFrames = 2000
    private let lock = NSRecursiveLock()
    private var phase = NativeRealtimeMediaLifecycle.inactive
    private var scope: NativeRealtimeMediaScope?
    private var samples = [Int16](repeating: 0, count: 240_000)
    private var readIndex = 0
    private var sampleCount = 0
    private var pending: [Pending] = []
    private var cursor: MediaOutputCursor?
    private var packetSequence: UInt64 = 0
    deinit { wipe() }
    var lifecycle: NativeRealtimeMediaLifecycle { lock.withLock { phase } }
    var queuedPCMBytes: Int { lock.withLock { sampleCount * 2 } }
    var queuedFrames: Int { lock.withLock { pending.count } }
    var ownedBuffersAreZero: Bool { lock.withLock { samples.allSatisfy { $0 == 0 } } }

    func activate(scope: NativeRealtimeMediaScope) throws {
        try operation {
            guard phase == .inactive else { throw NativeRealtimeMediaFailure.retired }
            self.scope = scope; phase = .current
        }
    }
    func retire(_ control: NativeRealtimeMediaControl = .scopeLost) { lock.withLock { retireOwned() } }

    /// Copies PCM before returning. Does not retain the decoder's callback storage.
    func offer(_ frame: NativeRealtimeMediaFrame) throws {
        try operation {
            guard phase == .current, let scope else { throw NativeRealtimeMediaFailure.inactive }
            guard frame.header.scope == scope else { throw NativeRealtimeMediaFailure.invalidScope }
            guard case .output(let output) = frame.header.payload else { throw NativeRealtimeMediaFailure.invalidFields }
            let count = frame.header.samplesPerChannel
            guard frame.pcm.count == count * 2 else { throw NativeRealtimeMediaFailure.invalidPCM }
            let next = try MediaOutputCursor.advance(cursor, output, samples: count)
            guard sampleCount + count <= samples.count, pending.count < Self.maximumPendingFrames else {
                throw NativeRealtimeMediaFailure.queueFull
            }
            for index in 0..<count {
                let value = UInt16(frame.pcm[index * 2]) | (UInt16(frame.pcm[index * 2 + 1]) << 8)
                samples[(readIndex + sampleCount + index) % samples.count] = Int16(bitPattern: value)
            }
            pending.append(Pending(output: output, samples: count, consumed: 0))
            sampleCount += count; cursor = next
        }
    }

    /// Returns exactly 240 samples (10 ms), or nil. Transport ownership/lease checks remain caller-owned.
    /// Returned bytes transfer to the caller; retirement clears only buffers this packetizer still owns.
    func pull() throws -> Packet? {
        try operation {
            guard phase == .current, let scope else { throw NativeRealtimeMediaFailure.inactive }
            guard sampleCount >= 240 else { return nil }
            guard packetSequence < NativeRealtimeMediaCodec.maximumSequence else { throw NativeRealtimeMediaFailure.invalidSequence }
            var pcm = [Int16](repeating: 0, count: 240)
            defer { pcm.withUnsafeMutableBytes { raw in _ = memset_s(raw.baseAddress!, raw.count, 0, raw.count) } }
            for index in 0..<240 {
                pcm[index] = samples[readIndex]; samples[readIndex] = 0
                readIndex = (readIndex + 1) % samples.count
            }
            sampleCount -= 240
            var segments: [Segment] = []
            var remaining = 240
            while remaining > 0 {
                let count = min(remaining, pending[0].samples - pending[0].consumed)
                segments.append(Segment(output: pending[0].output, offsetInFrame: pending[0].consumed, samples: count))
                pending[0].consumed += count; remaining -= count
                if pending[0].consumed == pending[0].samples { pending.removeFirst() }
            }
            packetSequence += 1
            return Packet(scope: scope, nativePacketSequence: packetSequence,
                audioPacket: pcm.withUnsafeBufferPointer { AudioPacket.pack(sampleRate: 24_000, channels: 1, samples: $0) },
                segments: segments)
        }
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            do { return try body() } catch { retireOwned(); throw error }
        }
    }
    private func wipe() {
        samples.withUnsafeMutableBytes { raw in _ = memset_s(raw.baseAddress!, raw.count, 0, raw.count) }
    }
    private func retireOwned() {
        wipe(); readIndex = 0; sampleCount = 0; pending.removeAll(keepingCapacity: false)
        cursor = nil; packetSequence = 0; scope = nil; phase = .retired
    }
}
