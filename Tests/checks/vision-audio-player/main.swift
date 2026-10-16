import Foundation
import os

var checks = 0
var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !ok() { failures += 1; print("FAIL \(name)") }
}
func ticket() -> VisionAudioTicket { .init(grant: UUID(), epoch: UUID()) }
let mono = VisionAudioFormat(rate: 8_000, channels: 1)!
let stereo = VisionAudioFormat(rate: 96_000, channels: 2)!
check(VisionAudioFormat(rate: .infinity, channels: 1) == nil, "reject infinite rate before allocation")
check(VisionAudioFormat(rate: .nan, channels: 1) == nil, "reject NaN rate")
check(VisionAudioFormat(rate: 7_999, channels: 1) == nil, "reject low rate")
check(VisionAudioFormat(rate: 96_001, channels: 1) == nil, "reject high rate")
check(VisionAudioFormat(rate: 48_000, channels: 3) == nil, "reject multichannel")
check(mono.prefill == 320 && mono.ceiling == 1200 && mono.newest == 480, "exact mono timing")
check(stereo.ceiling == VisionAudioRing.maximumFrames, "finite maximum ring")

let ring = VisionAudioRing()
ring.configure(mono)
check(ring.append([Float](repeating: 0.25, count: 319)), "admit valid PCM")
check(!ring.readFrame(into: { _, _ in }), "prefill holds 39ms")
check(ring.append([0.75]), "admit prefill boundary")
var first: Float = -1
check(ring.readFrame(into: { _, value in first = value }), "40ms starts rendering")
check(first == 0.25, "consume oldest admitted frame")
for _ in 0..<319 { _ = ring.readFrame(into: { _, _ in }) }
check(!ring.readFrame(into: { _, _ in }) && !ring.ready && ring.count == 0, "underrun waits for fresh prefill")
check(!ring.append([.nan]) && ring.count == 0, "reject nonfinite PCM atomically")
ring.configure(stereo)
check(!ring.append([1]) && ring.count == 0, "reject partial channel frame")
check(!ring.append([Float](repeating: 1, count: 32_769)), "reject decoded sample allocation limit")

ring.configure(mono)
_ = ring.append((0..<1200).map(Float.init))
check(ring.count == 1200, "150ms ceiling inclusive")
_ = ring.append([1200])
check(ring.count == 480, "overflow trims to newest 60ms")
first = -1
_ = ring.readFrame(into: { _, value in first = value })
check(first == 721, "trim preserves newest chronological frames")
ring.clear()
_ = ring.append((0..<16000).map(Float.init))
check(ring.count == 480, "oversize valid decoded block retains newest bound")
_ = ring.readFrame(into: { _, value in first = value })
check(first == 15520, "oversize block starts at newest suffix")
for _ in 0..<100 {
    _ = ring.append([Float](repeating: 0.5, count: 333))
    for _ in 0..<111 { _ = ring.readFrame(into: { _, _ in }) }
    check(ring.count <= mono.ceiling, "wrap remains bounded")
}
ring.configure(stereo)
_ = ring.append((0..<stereo.prefill).flatMap { _ in [Float(0.2), Float(0.8)] })
var channels: [Float] = []
_ = ring.readFrame(into: { _, value in channels.append(value) })
check(channels == [0.2, 0.8], "stereo order preserved")

let a = ticket(), b = ticket()
var mailbox = VisionAudioMailbox()
check(mailbox.offer(Data([1]), ticket: a, now: 0), "first packet schedules drain")
for _ in 0..<7 { check(!mailbox.offer(Data([2]), ticket: a, now: 0), "burst coalesces drain") }
check(mailbox.count == 8 && mailbox.scheduled, "at most eight queued")
let gap = mailbox.gap
check(!mailbox.offer(Data([3]), ticket: a, now: 0), "overflow does not schedule another drain")
check(mailbox.count == 8 && mailbox.gap > gap, "drop marks decoder discontinuity")
let work = mailbox.next(now: 0)!
check(work.data == Data([2]) && mailbox.inFlight, "oldest drop admits fresh newest packet")
_ = mailbox.offer(Data([4]), ticket: a, now: 0.05)
check(mailbox.count == 8 && mailbox.inFlight, "one inflight plus bounded mailbox")
mailbox.finish()
mailbox.clear()
check(mailbox.scheduled && mailbox.count == 0, "revocation retains single worker ownership")
check(!mailbox.offer(Data([5]), ticket: b, now: 1), "new epoch reuses existing drain")
let next = mailbox.next(now: 1)!
check(next.ticket == b, "old drain can carry new grant work without old data")
mailbox.finish()
check(mailbox.next(now: 1) == nil && !mailbox.scheduled, "drain becomes idle atomically")
check(mailbox.offer(Data(repeating: 0, count: 32768), ticket: a, now: 2), "packet boundary admitted")
for _ in 0..<4 { _ = mailbox.offer(Data(repeating: 1, count: 32768), ticket: a, now: 2) }
check(mailbox.bytes == 131072 && mailbox.count == 4, "128KiB total ceiling")
let beforeReject = mailbox.gap
_ = mailbox.offer(Data(repeating: 1, count: 32769), ticket: a, now: 2)
check(mailbox.bytes == 131072 && mailbox.gap > beforeReject, "32KiB individual ceiling and gap")
check(mailbox.next(now: 2.101) == nil && mailbox.bytes == 0, "100ms queued expiry clears drain")
_ = mailbox.offer(Data([8]), ticket: a, now: 3)
let fresh = mailbox.next(now: 3.05)!
check(mailbox.isFresh(fresh, now: 3.1), "100ms freshness inclusive")
check(!mailbox.isFresh(fresh, now: 3.101), "inflight age checked after decode")
mailbox.invalidateDecode()
check(!mailbox.isFresh(fresh, now: 3.05), "gap invalidates inflight result")
mailbox.finish()

var state = VisionAudioPlaybackState()
state.begin(a)
_ = state.mailbox.offer(Data([1]), ticket: a, now: 5)
let admitted = state.mailbox.next(now: 5)!
check(state.append([Float](repeating: 1, count: 320), format: mono, work: admitted, now: 5), "admitted decoded samples")
let version = state.version
check(state.rendered == .waiting, "append and engine readiness do not claim rendering")
var writes = 0
state.render(ticket: a, version: version, frames: 1) { _, _, _ in writes += 1 }
check(writes == 1 && state.rendered == .rendering, "render consumes PCM before rendering state")
_ = state.revoke()
state.render(ticket: a, version: version, frames: 1) { _, _, _ in writes += 1 }
check(writes == 1 && state.ring.count == 0 && state.rendered == .waiting, "stop revokes render and clears PCM synchronously")
check(!state.append([1], format: mono, work: admitted, now: 5), "late decode cannot resurrect stopped grant")
state.begin(b)
check(!state.admits(a) && state.admits(b), "new epoch rejects stale grant")
state.render(ticket: a, version: version, frames: 1) { _, _, _ in writes += 1 }
check(writes == 1, "stale source node cannot consume new epoch")
state.fail(a, message: "stale")
check(state.failure == nil && state.admits(b), "stale failure cannot revoke new grant")
state.fail(b, message: "decoder")
check(!state.admits(b) && state.failure == "decoder" && state.ring.count == 0, "failure closes admission and clears render")

var lease = VisionAudioLease()
check(lease.acquire(a.epoch), "first owner acquires lease")
check(!lease.acquire(b.epoch) && lease.owner == a.epoch, "second window cannot take active lease")
check(!lease.release(b.epoch) && lease.owner == a.epoch, "foreign cleanup cannot release owner")
check(lease.release(a.epoch) && lease.acquire(b.epoch), "owner cleanup allows next window")
check(!lease.release(a.epoch) && lease.owner == b.epoch, "late cleanup cannot release new owner")

let sdkLock = OSAllocatedUnfairLock(initialState: 0)
let acquired: Bool? = sdkLock.withLockIfAvailable { value in value += 1; return true }
check(acquired == true, "SDK supports nonblocking render lock")
sdkLock.withLock { _ in
    let busy: Bool? = sdkLock.withLockIfAvailable { _ in true }
    check(busy == nil, "busy render lock returns without blocking")
}
print("Vision audio pure checks: \(checks - failures)/\(checks) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
