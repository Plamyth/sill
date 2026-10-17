private final class RemoteAACDecoder {
    static var decoding: (() -> Void)?
    init?(rate: Double, channels: Int, cookie: Data) {}
    func matches(rate: Double, channels: Int, cookie: Data) -> Bool { true }
    func decode(_ packet: Data) -> [Float]? {
        Self.decoding?()
        return Array(repeating: 0.25, count: 2400)
    }
}
func holdAudioDecode(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
    RemoteAACDecoder.decoding = { entered.signal(); release.wait() }
}
final class FakeAudioSourceNode {
    init(format: AVAudioFormat, renderBlock: @escaping (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, AVAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> OSStatus) {}
}
final class FakeAudioEngine {
    static var failStart = false
    static var starts = 0
    var stopped = false
    var isRunning = false
    let mainMixerNode = 0
    func stop() { stopped = true; isRunning = false }
    func attach(_ source: FakeAudioSourceNode) {}
    func connect(_ source: FakeAudioSourceNode, to: Int, format: AVAudioFormat) {}
    func start() throws {
        Self.starts += 1
        if Self.failStart { throw NSError(domain: "TestEngine", code: 42) }
        isRunning = true
    }
}
final class IPadAudioSession {
    enum Role { case remotePlayback }
    static let shared = IPadAudioSession()
    var releases = 0
    var failRelease = false
    private var leases: Set<UUID> = []
    func acquire(_ role: Role, leaseId: UUID) throws { leases.insert(leaseId) }
    func holds(leaseId: UUID) -> Bool { leases.contains(leaseId) }
    func release(leaseId: UUID) throws {
        if failRelease { throw NSError(domain: "AudioSession", code: 1) }
        releases += 1
        leases.remove(leaseId)
    }
}
