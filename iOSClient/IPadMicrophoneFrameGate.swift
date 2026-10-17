import Foundation
import Network
import os
import StreamProtocol

/// Frames belong to one connection and one Mac grant. Closing waits for any in-flight send call
/// to return, so a later stop control cannot be overtaken by a new frame.
final class IPadMicrophoneFrameGate: @unchecked Sendable {
    typealias Send = @Sendable (NWConnection, Data, @escaping @Sendable () -> Void) -> Void

    private struct Binding {
        let connection: NWConnection
        let scope: MicrophoneScope
        let grant: UUID
        let captureID: UUID
        let generation: UUID
        let diagnostics: IPadMicrophoneDiagnostics.Attempt?
        var pending = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: Optional<Binding>.none)
    private let send: Send

    init(send: @escaping Send = { connection, bytes, done in
        connection.send(content: bytes, completion: .contentProcessed { _ in done() })
    }) {
        self.send = send
    }

    func open(connection: NWConnection, scope: MicrophoneScope, grant: UUID, captureID: UUID,
              diagnostics: IPadMicrophoneDiagnostics.Attempt? = nil) {
        diagnostics?.record("gate_open")
        lock.withLock { $0 = Binding(connection: connection, scope: scope,
                                     grant: grant, captureID: captureID, generation: UUID(), diagnostics: diagnostics) }
    }

    func close() {
        lock.withLock { $0?.diagnostics?.record("gate_closed"); $0 = nil }
    }

    func close(captureID: UUID) {
        lock.withLock { binding in
            if binding?.captureID == captureID { binding?.diagnostics?.record("gate_closed"); binding = nil }
        }
    }

    func emit(_ block: IPadMicrophonePCMFrame, captureID: UUID) {
        emitBatch([block], captureID: captureID)
    }

    func emitBatch(_ blocks: [IPadMicrophonePCMFrame], captureID: UUID,
                   diagnostics: IPadMicrophoneDiagnostics.Attempt? = nil) {
        guard !blocks.isEmpty, blocks.count <= IPadMicrophonePCM.maxBatchPackets else {
            diagnostics?.record("gate_drop_batch_size", ["packets": String(blocks.count)])
            return
        }
        lock.withLock { binding in
            guard var current = binding else { diagnostics?.record("gate_drop_unbound"); return }
            let log = diagnostics ?? current.diagnostics
            guard current.captureID == captureID else { log?.record("gate_drop_capture_mismatch"); return }
            guard current.pending < 2 else { log?.record("gate_drop_backpressure"); return }
            var bytes = Data()
            bytes.reserveCapacity(blocks.count * (StreamMessage.headerLength + MicrophoneWire.frameLimit))
            for block in blocks {
                guard let frame = MicrophoneFrame(scope: current.scope, grantID: current.grant,
                                                  sequence: block.sequence, frameCount: block.frameCount,
                                                  pcm: block.pcm) else { log?.record("gate_drop_invalid_frame"); return }
                let message = StreamMessage(kind: .microphoneFrame, timestamp: Date().timeIntervalSince1970,
                                            isKeyframe: false, payload: frame.encoded())
                bytes.append(message.serialized())
            }
            current.pending += 1
            binding = current
            let generation = current.generation
            log?.record("first_gate_send", ["packets": String(blocks.count), "bytes": String(bytes.count), "sequence": String(blocks[0].sequence), "pending": String(current.pending)])
            send(current.connection, bytes) { [weak self] in self?.complete(generation: generation) }
        }
    }

    private func complete(generation: UUID) {
        lock.withLock { binding in
            guard binding?.generation == generation else { return }
            binding?.diagnostics?.record("first_gate_send_completion")
            binding?.pending -= 1
        }
    }
}
