import Foundation
import Combine
import os

final class FixtureQueue {
    static let main = FixtureQueue()
    private let lock = NSLock()
    private var work: [() -> Void] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
    func async(execute: @escaping () -> Void) { lock.lock(); work.append(execute); lock.unlock() }
    func drain() {
        while true {
            lock.lock()
            let next = work.isEmpty ? nil : work.removeFirst()
            lock.unlock()
            guard let next else { return }
            next()
        }
    }
}
enum VisionAudioPlaybackEvent { case rendering, waiting, failed(String) }
final class VisionAudioPlayer {
    var cleanupProblem: String?
    var onCleanupChange: ((String?) -> Void)?
    var delivered: [(Data, UUID, TimeInterval)] = []
    var gaps: [UInt64] = []
    func retryCleanup() {}
    func begin(grant: UUID, onEvent: @escaping (UUID, VisionAudioPlaybackEvent) -> Void) {}
    func receive(_ data: Data, grant: UUID) { delivered.append((data, grant, -1)) }
    func receive(_ data: Data, grant: UUID, arrived: TimeInterval, gap: UInt64) {
        delivered.append((data, grant, arrived))
        gaps.append(gap)
    }
    func stop() {}
}
final class NWConnection {}
enum StreamSource: Equatable { case none, desktop, window(UInt32) }
enum Direction { case playback }
final class VisionRemoteAudioStore {
    static let shared = VisionRemoteAudioStore()
    var allowed = true
    func permits(_ client: StreamClient, direction: Direction) -> Bool { allowed }
}
final class StreamClient {
    var connection: NWConnection?
    let visionAudioRoute = VisionAudioRoute()
    let visionAudio: VisionAudioController
    init(_ controller: VisionAudioController, peer: NWConnection) {
        visionAudio = controller; connection = peer
        _ = visionAudioRoute.observe(peer, source: .desktop, supported: true)
    }
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { fatalError("FAIL " + label) }
}
var now = 100.0
var allowed = true
let player = VisionAudioPlayer()
var controls: [VisionAudioControl] = []
let controller = VisionAudioController(send: { controls.append($0) }, player: player,
    clock: { now }, permitted: { allowed })
let peer = NWConnection()
let client = StreamClient(controller, peer: peer)
let scope = client.visionAudioRoute.scope(for: peer)!
func activate() {
    controller.update(.available(scope))
    controller.setForeground(true)
    check(controller.enable(), "fresh local playback request")
    let control = controls.last { $0.enabled }!
    controller.acknowledge(id: control.requestID, enabled: true, scope: scope, reason: nil)
    FixtureQueue.main.drain()
}
let network = DispatchQueue(label: "checks.network.ingress")
func flood(_ count: Int, bytes: Int = 32 * 1024) {
    let done = DispatchSemaphore(value: 0)
    network.async {
        for _ in 0..<count { client.receiveAudio(Data(repeating: 7, count: bytes), from: peer) }
        done.signal()
    }
    done.wait()
}
activate()
flood(10_000)
check(FixtureQueue.main.count == 1, "blocked main retains one drain rather than one Data closure per packet")
check(player.delivered.isEmpty, "blocked main cannot forward packets before native binding check")
FixtureQueue.main.drain()
check(player.delivered.count == VisionAudioMailbox.byteLimit / VisionAudioMailbox.packetByteLimit,
      "blocked main retains at most 128KiB of packet data")
check(player.delivered.allSatisfy { $0.2 == 100 }, "player receives original network arrival time")
let overflowGap = player.gaps.last!
player.delivered.removeAll()
flood(100, bytes: 1)
FixtureQueue.main.drain()
check(player.delivered.count == VisionAudioMailbox.packetLimit, "small packets retain only eight bounded entries")
check(player.gaps.last! > overflowGap, "ingress overflow carries decode discontinuity to the real player boundary")
player.delivered.removeAll()
flood(1)
now += 0.101
FixtureQueue.main.drain()
check(player.delivered.isEmpty, "packets older than 100ms while main blocked are dropped")
flood(1)
allowed = false
FixtureQueue.main.drain()
check(player.delivered.isEmpty, "native binding revoked before main delivery rejects queued audio")
allowed = true
flood(1)
controller.stop()
activate()
FixtureQueue.main.drain()
check(player.delivered.isEmpty, "old grant frames cannot be promoted into a new generation")
flood(1)
FixtureQueue.main.drain()
check(player.delivered.count == 1 && player.delivered[0].1 == controls.last { $0.enabled }!.grant.id,
      "fresh new generation audio still passes native authority and original grant")
print("PASS \(checks) bounded ingress production adapter assertions")
