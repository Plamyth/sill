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
    func prepareMicrophone(grant: HostLocalOwnerGrant,
                           render: MicrophoneRenderBuffer) async -> HostMicrophonePreparation
    func restoreMicrophoneForExit()
}

extension HostMicrophoneOriginalOwner {
    func prepareMicrophone(grant: HostLocalOwnerGrant,
                           render: MicrophoneRenderBuffer) async -> HostMicrophonePreparation {
        await HALMicrophoneSink.prepare(grant: grant, render: render)
    }
    func restoreMicrophoneForExit() {}
}

package final class MicrophoneRenderBuffer: @unchecked Sendable {
    private struct Storage {
        var open = true
        var admitted = false
        var head = 0
        var packetCount = 0
        var rendered: UInt64 = 0
        var queueAgeMilliseconds: Double = 0
        var droppedPackets: UInt64 = 0
    }
    private struct Slot {
        var length = 0
        var offset = 0
        var arrived: UInt64 = 0
    }
    private static let packetCapacity = 6
    private let state = OSAllocatedUnfairLock(initialState: Storage())
    private let samples = UnsafeMutablePointer<Int16>.allocate(capacity: packetCapacity * MicrophoneWire.maxFrames)
    private let slots = UnsafeMutablePointer<Slot>.allocate(capacity: packetCapacity)
    let grant: HostLocalOwnerGrant
    let monotonicNow: () -> UInt64
    static let maxQueueAge: UInt64 = 160_000_000

    init(grant: HostLocalOwnerGrant, now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.grant = grant; monotonicNow = now
        samples.initialize(repeating: 0, count: Self.packetCapacity * MicrophoneWire.maxFrames)
        slots.initialize(repeating: Slot(), count: Self.packetCapacity)
    }
    deinit {
        samples.deinitialize(count: Self.packetCapacity * MicrophoneWire.maxFrames); samples.deallocate()
        slots.deinitialize(count: Self.packetCapacity); slots.deallocate()
    }

    func close() { state.withLock { $0.open = false; $0.packetCount = 0; $0.head = 0 } }
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
        let decoded: [Int16] = (0..<frame.frameCount).map { i in
            let offset = frame.pcm.startIndex + i * 2
            return Int16(bitPattern: UInt16(frame.pcm[offset]) | UInt16(frame.pcm[offset + 1]) << 8)
        }
        return state.withLock { value in
            guard value.open, value.admitted else { return false }
            return grant.whileValid(at: now) {
                let tail = (value.head + value.packetCount) % Self.packetCapacity
                if value.packetCount == Self.packetCapacity {
                    value.head = (value.head + 1) % Self.packetCapacity
                    if value.droppedPackets < UInt64.max { value.droppedPackets += 1 }
                } else { value.packetCount += 1 }
                slots[tail] = Slot(length: frame.frameCount, offset: 0, arrived: arrived)
                decoded.withUnsafeBufferPointer { source in
                    samples.advanced(by: tail * MicrophoneWire.maxFrames)
                        .update(from: source.baseAddress!, count: frame.frameCount)
                }
            }
        }
    }

    func render(frames: Int, now: UInt64, write: (Int, Int16) -> Void) {
        guard frames > 0, frames <= MicrophoneWire.maxFrames else { return }
        _ = state.withLockIfAvailable { value in
            guard value.open, value.admitted else { return }
            grant.renderIfValid(at: now) {
                var output = 0
                while output < frames && value.packetCount > 0 {
                    let index = value.head
                    var slot = slots[index]
                    guard now >= slot.arrived, now - slot.arrived <= Self.maxQueueAge else {
                        value.head = (index + 1) % Self.packetCapacity
                        value.packetCount -= 1
                        if value.droppedPackets < UInt64.max { value.droppedPackets += 1 }
                        continue
                    }
                    let count = min(frames - output, slot.length - slot.offset)
                    for i in 0..<count {
                        write(output + i, samples[index * MicrophoneWire.maxFrames + slot.offset + i])
                    }
                    output += count; slot.offset += count
                    value.rendered = value.rendered > UInt64.max - UInt64(count) ? UInt64.max : value.rendered + UInt64(count)
                    value.queueAgeMilliseconds = Double(now - slot.arrived) / 1_000_000
                    if slot.offset == slot.length {
                        value.head = (index + 1) % Self.packetCapacity
                        value.packetCount -= 1
                    } else { slots[index] = slot }
                }
            }
        }
    }

    var counters: (UInt64, Double, UInt64) {
        state.withLock { ($0.rendered, $0.queueAgeMilliseconds, $0.droppedPackets) }
    }
}
