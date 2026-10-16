import Foundation
import StreamProtocol
import Network
import os

package struct HostMicrophoneDestination: Equatable {
    package let outputUID: String
    package let inputUID: String
    package let pluginBundleID: String
    package let outputChannels: Int
    package let inputChannels: Int
    package let outputChannel: Int
    package let inputChannel: Int

    package init?(outputUID: String, inputUID: String, pluginBundleID: String,
                  outputChannels: Int, inputChannels: Int, outputChannel: Int, inputChannel: Int) {
        guard !outputUID.isEmpty, !inputUID.isEmpty, !pluginBundleID.isEmpty,
              (1...32).contains(outputChannels), (1...32).contains(inputChannels),
              (0..<outputChannels).contains(outputChannel), (0..<inputChannels).contains(inputChannel) else { return nil }
        self.outputUID = outputUID; self.inputUID = inputUID; self.pluginBundleID = pluginBundleID
        self.outputChannels = outputChannels; self.inputChannels = inputChannels
        self.outputChannel = outputChannel; self.inputChannel = inputChannel
    }
}

package final class HostLocalOwnerGrant: @unchecked Sendable {
    package let owner: UUID
    package let callGeneration: UUID
    package let scope: MicrophoneScope
    package let fingerprint: Data
    package let destination: HostMicrophoneDestination
    package let expiresAt: UInt64
    private let revoked = OSAllocatedUnfairLock(initialState: false)

    package init(owner: UUID, callGeneration: UUID, scope: MicrophoneScope, fingerprint: Data,
                 destination: HostMicrophoneDestination, expiresAt: UInt64) {
        self.owner = owner; self.callGeneration = callGeneration; self.scope = scope
        self.fingerprint = fingerprint; self.destination = destination; self.expiresAt = expiresAt
    }

    package func revoke() { revoked.withLock { $0 = true } }
    func valid(at now: UInt64) -> Bool { now < expiresAt && revoked.withLock { !$0 } }
    func whileValid(at now: UInt64, _ operation: () -> Void) -> Bool {
        revoked.withLock { value in
            guard !value, now < expiresAt else { return false }
            operation()
            return true
        }
    }
    func renderIfValid(at now: UInt64, _ operation: () -> Void) {
        _ = revoked.withLockIfAvailable { value in
            if !value, now < expiresAt { operation() }
        }
    }
}

@MainActor
package protocol HostMicrophoneOriginalOwner: AnyObject {
    func microphoneGrant(peer: UUID, source: StreamSource, inputGeneration: UUID, videoEpoch: UUID,
                         fingerprint: Data) -> HostLocalOwnerGrant?
}

final class MicrophoneRenderBuffer: @unchecked Sendable {
    private struct Storage {
        var open = true
        var admitted = false
        var count = 0
        var offset = 0
        var arrived: UInt64 = 0
        var rendered: UInt64 = 0
        var queueAgeMilliseconds: Double = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: Storage())
    private let samples = UnsafeMutablePointer<Int16>.allocate(capacity: MicrophoneWire.maxFrames)
    let grant: HostLocalOwnerGrant
    let monotonicNow: () -> UInt64
    static let maxQueueAge: UInt64 = 60_000_000

    init(grant: HostLocalOwnerGrant, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.grant = grant; monotonicNow = now
        samples.initialize(repeating: 0, count: MicrophoneWire.maxFrames)
    }
    deinit { samples.deinitialize(count: MicrophoneWire.maxFrames); samples.deallocate() }

    func close() { state.withLock { $0.open = false; $0.count = 0; $0.offset = 0 } }
    var isOpen: Bool { state.withLock { $0.open } }
    var isAdmitted: Bool { state.withLock { $0.open && $0.admitted } }
    @discardableResult
    func sendEnabled(_ data: Data, to connection: NWConnection) -> Bool {
        state.withLock { value in
            guard value.open else { return false }
            return grant.whileValid(at: monotonicNow()) {
                value.admitted = true
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    func offer(_ frame: MicrophoneFrame, arrived: UInt64, now: UInt64) -> Bool {
        guard now >= arrived, now - arrived <= Self.maxQueueAge, grant.valid(at: now) else { return false }
        return state.withLock { value in
            guard value.open, value.admitted else { return false }
            return grant.whileValid(at: now) {
                for i in 0..<frame.frameCount {
                    let offset = frame.pcm.startIndex + i * 2
                    samples[i] = Int16(bitPattern: UInt16(frame.pcm[offset]) | UInt16(frame.pcm[offset + 1]) << 8)
                }
                value.count = frame.frameCount; value.offset = 0; value.arrived = arrived
            }
        }
    }

    func render(frames: Int, now: UInt64, write: (Int, Int16) -> Void) {
        guard frames > 0, frames <= MicrophoneWire.maxFrames else { return }
        _ = state.withLockIfAvailable { value in
            guard value.open, value.admitted, now >= value.arrived,
                  now - value.arrived <= Self.maxQueueAge else { value.count = 0; return }
            grant.renderIfValid(at: now) {
                let count = min(frames, value.count - value.offset)
                for i in 0..<count { write(i, samples[value.offset + i]) }
                value.offset += count
                value.rendered = value.rendered > UInt64.max - UInt64(count) ? UInt64.max : value.rendered + UInt64(count)
                value.queueAgeMilliseconds = Double(now - value.arrived) / 1_000_000
            }
        }
    }

    var counters: (UInt64, Double) { state.withLock { ($0.rendered, $0.queueAgeMilliseconds) } }
}
