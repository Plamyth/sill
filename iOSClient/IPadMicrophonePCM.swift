import Foundation

/// One 20 ms, 48 kHz mono S16LE block. The transport binds it to a host grant and scope.
struct IPadMicrophonePCMFrame: Equatable {
    let sequence: UInt64
    let frameCount: Int
    let pcm: Data
}

/// Converts resampled mono Float32 into bounded wire blocks without retaining an audio backlog.
struct IPadMicrophonePCM {
    static let sampleRate = 48_000
    static let framesPerPacket = 960

    private var pending: [Int16] = []
    private var nextSequence: UInt64 = 1

    mutating func append(_ samples: UnsafeBufferPointer<Float>, emit: (IPadMicrophonePCMFrame) -> Void) {
        for sample in samples {
            guard nextSequence != UInt64.max else { return }
            let clamped = sample.isFinite ? min(1, max(-1, sample)) : 0
            let scale: Float = clamped < 0 ? 32_768 : 32_767
            pending.append(Int16((clamped * scale).rounded()))
            guard pending.count == Self.framesPerPacket else { continue }
            var bytes = Data(capacity: Self.framesPerPacket * 2)
            for value in pending {
                let bits = UInt16(bitPattern: value)
                bytes.append(UInt8(truncatingIfNeeded: bits))
                bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            }
            emit(IPadMicrophonePCMFrame(sequence: nextSequence,
                                       frameCount: Self.framesPerPacket, pcm: bytes))
            nextSequence += 1
            pending.removeAll(keepingCapacity: true)
        }
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        nextSequence = 1
    }
}
