import Foundation
import Network
import StreamProtocol

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var packets: [(NWConnection, Data, @Sendable () -> Void)] = []

    func record(_ connection: NWConnection, _ bytes: Data, _ done: @escaping @Sendable () -> Void) {
        lock.lock()
        packets.append((connection, bytes, done))
        lock.unlock()
    }
}

let recorder = Recorder()
let gate = IPadMicrophoneFrameGate(send: { connection, bytes, done in
    recorder.record(connection, bytes, done)
})
let first = NWConnection(host: "127.0.0.1", port: 9991, using: .tcp)
let second = NWConnection(host: "127.0.0.1", port: 9992, using: .tcp)
let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: UUID(),
                            videoEpoch: UUID(), destination: UUID(), capability: UUID())
let grant = UUID()
let firstCapture = UUID()
let secondCapture = UUID()
func block(_ sequence: UInt64) -> IPadMicrophonePCMFrame {
    IPadMicrophonePCMFrame(sequence: sequence, frameCount: 960, pcm: Data(repeating: 0, count: 1920))
}

gate.emit(block(1), captureID: firstCapture)
precondition(recorder.packets.isEmpty)
gate.open(connection: first, scope: scope, grant: grant, captureID: firstCapture)
gate.emit(block(1), captureID: firstCapture)
gate.emit(block(2), captureID: firstCapture)
gate.emit(block(3), captureID: firstCapture)
precondition(recorder.packets.count == 2)
for (index, packet) in recorder.packets.enumerated() {
    precondition(packet.0 === first)
    let header = StreamMessage.parseHeader(packet.1)!
    precondition(header.kind == .microphoneFrame && header.payloadLength == 2033)
    let frame = MicrophoneFrame(encoded: Data(packet.1.dropFirst(StreamMessage.headerLength)))!
    precondition(frame.scope == scope && frame.grantID == grant && frame.sequence == UInt64(index + 1))
}

gate.close()
gate.emit(block(4), captureID: firstCapture)
precondition(recorder.packets.count == 2)
gate.open(connection: second, scope: scope, grant: UUID(), captureID: secondCapture)
gate.emit(block(4), captureID: firstCapture)
precondition(recorder.packets.count == 2)
gate.emit(block(1), captureID: secondCapture)
gate.emit(block(2), captureID: secondCapture)
precondition(recorder.packets.count == 4)
recorder.packets[0].2()
gate.emit(block(3), captureID: secondCapture)
precondition(recorder.packets.count == 4)
recorder.packets[2].2()
gate.emit(block(3), captureID: secondCapture)
precondition(recorder.packets.count == 5 && recorder.packets[4].0 === second)

gate.close()
let batchCapture = UUID()
gate.open(connection: second, scope: scope, grant: grant, captureID: batchCapture)
gate.emitBatch((1...5).map { block(UInt64($0)) }, captureID: batchCapture)
precondition(recorder.packets.count == 6)
let batch = recorder.packets[5].1
var offset = 0
for sequence in 1...5 {
    let remaining = Data(batch.dropFirst(offset))
    let header = StreamMessage.parseHeader(remaining)!
    precondition(header.kind == .microphoneFrame)
    let start = offset + StreamMessage.headerLength
    let end = start + header.payloadLength
    precondition(end <= batch.count)
    let frame = MicrophoneFrame(encoded: batch.subdata(in: start..<end))!
    precondition(frame.scope == scope && frame.grantID == grant && frame.sequence == UInt64(sequence))
    offset = end
}
precondition(offset == batch.count)
gate.emitBatch((6...10).map { block(UInt64($0)) }, captureID: firstCapture)
precondition(recorder.packets.count == 6)
print("iPad microphone frame gate passed")
