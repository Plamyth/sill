import Foundation

enum VisionAudioPlaybackAuthorization { case current, superseded, revoked }

struct VisionAudioFormat: Equatable, Sendable {
    let rate: Double
    let channels: Int
    let prefill: Int
    let ceiling: Int
    let newest: Int

    init?(rate: Double, channels: Int) {
        guard rate.isFinite, (8_000...96_000).contains(rate), (1...2).contains(channels) else { return nil }
        self.rate = rate
        self.channels = channels
        prefill = Int(ceil(rate * 0.040))
        ceiling = Int(floor(rate * 0.150))
        newest = Int(ceil(rate * 0.060))
    }
}

struct VisionAudioTicket: Equatable, Sendable {
    let grant: UUID
    let epoch: UUID
}

enum VisionAudioRenderState: Equatable, Sendable {
    case waiting
    case rendering
}

final class VisionAudioRing {
    static let maximumFrames = 14_400
    private let storage: UnsafeMutablePointer<Float>
    private(set) var format: VisionAudioFormat?
    private(set) var count = 0
    private var head = 0
    private(set) var ready = false

    init() {
        storage = .allocate(capacity: Self.maximumFrames * 2)
        storage.initialize(repeating: 0, count: Self.maximumFrames * 2)
    }

    deinit {
        storage.deinitialize(count: Self.maximumFrames * 2)
        storage.deallocate()
    }

    func clear() {
        count = 0
        head = 0
        ready = false
    }

    func configure(_ format: VisionAudioFormat) {
        clear()
        self.format = format
    }

    @discardableResult
    func append(_ samples: [Float]) -> Bool {
        guard let format, !samples.isEmpty, samples.count <= 32_768,
              samples.count % format.channels == 0, samples.allSatisfy({ $0.isFinite }) else { return false }
        let frames = samples.count / format.channels
        let retained = count + frames > format.ceiling ? format.newest : count + frames
        let discarded = max(0, count + frames - retained)
        let oldDrop = min(count, discarded)
        head = (head + oldDrop) % Self.maximumFrames
        count -= oldDrop
        let incomingStart = discarded - oldDrop
        for frame in incomingStart..<frames {
            let destination = (head + count) % Self.maximumFrames
            for channel in 0..<format.channels {
                storage[destination * 2 + channel] = samples[frame * format.channels + channel]
            }
            count += 1
        }
        if !ready && count >= format.prefill { ready = true }
        return true
    }

    func readFrame(into write: (Int, Float) -> Void) -> Bool {
        guard let format, ready, count > 0 else {
            ready = false
            return false
        }
        for channel in 0..<format.channels { write(channel, storage[head * 2 + channel]) }
        head = (head + 1) % Self.maximumFrames
        count -= 1
        if count == 0 { ready = false }
        return true
    }
}

struct VisionAudioMailbox {
    static let packetLimit = 8
    static let byteLimit = 128 * 1024
    static let packetByteLimit = 32 * 1024
    static let ageLimit: TimeInterval = 0.100

    struct Work {
        let data: Data
        let ticket: VisionAudioTicket
        let arrived: TimeInterval
        let gap: UInt64
    }

    private struct Entry {
        let data: Data
        let ticket: VisionAudioTicket
        let arrived: TimeInterval
    }

    private var slots = [Entry?](repeating: nil, count: packetLimit)
    private var head = 0
    private(set) var count = 0
    private(set) var bytes = 0
    private(set) var gap: UInt64 = 0
    private(set) var scheduled = false
    private(set) var inFlight = false

    mutating func clear() {
        for index in slots.indices { slots[index] = nil }
        head = 0
        count = 0
        bytes = 0
        gap &+= 1
        // A revoked worker still owns the drain until it observes the empty mailbox.
    }

    private mutating func drop() {
        guard count > 0 else { return }
        bytes -= slots[head]!.data.count
        slots[head] = nil
        head = (head + 1) % Self.packetLimit
        count -= 1
    }

    private mutating func expire(now: TimeInterval) {
        while let entry = slots[head], now > entry.arrived + Self.ageLimit {
            drop()
            gap &+= 1
        }
    }

    mutating func offer(_ data: Data, ticket: VisionAudioTicket, now: TimeInterval) -> Bool {
        expire(now: now)
        guard !data.isEmpty, data.count <= Self.packetByteLimit else {
            gap &+= 1
            return false
        }
        while count == Self.packetLimit || bytes + data.count > Self.byteLimit {
            drop()
            gap &+= 1
        }
        slots[(head + count) % Self.packetLimit] = Entry(data: data, ticket: ticket, arrived: now)
        count += 1
        bytes += data.count
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    mutating func next(now: TimeInterval) -> Work? {
        precondition(!inFlight)
        expire(now: now)
        guard count > 0 else {
            scheduled = false
            return nil
        }
        let entry = slots[head]!
        drop()
        inFlight = true
        return Work(data: entry.data, ticket: entry.ticket, arrived: entry.arrived, gap: gap)
    }

    mutating func finish() { inFlight = false }

    mutating func invalidateDecode() { gap &+= 1 }

    func isFresh(_ work: Work, now: TimeInterval) -> Bool {
        work.gap == gap && now >= work.arrived && now <= work.arrived + Self.ageLimit
    }
}

struct VisionAudioLease {
    private(set) var owner: UUID?

    mutating func acquire(_ candidate: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }

    @discardableResult
    mutating func release(_ candidate: UUID) -> Bool {
        guard owner == candidate else { return false }
        owner = nil
        return true
    }
}

struct VisionAudioPlaybackState {
    private(set) var ticket: VisionAudioTicket?
    private(set) var failure: String?
    let ring = VisionAudioRing()
    var mailbox = VisionAudioMailbox()
    private(set) var version: UInt64 = 0
    private(set) var rendered: VisionAudioRenderState = .waiting
    private var lastAdmission: TimeInterval?

    mutating func begin(_ ticket: VisionAudioTicket) {
        revoke()
        self.ticket = ticket
    }

    @discardableResult
    mutating func revoke() -> VisionAudioTicket? {
        let old = ticket
        ticket = nil
        failure = nil
        ring.clear()
        mailbox.clear()
        version &+= 1
        rendered = .waiting
        lastAdmission = nil
        return old
    }

    func admits(_ ticket: VisionAudioTicket) -> Bool {
        self.ticket == ticket && failure == nil
    }

    mutating func fail(_ ticket: VisionAudioTicket, message: String) {
        guard admits(ticket) else { return }
        ring.clear()
        mailbox.clear()
        version &+= 1
        failure = message
        rendered = .waiting
        lastAdmission = nil
    }

    mutating func replaceFailure(_ message: String) {
        guard failure != nil else { return }
        failure = message
    }

    func hasFreshPCM(now: TimeInterval) -> Bool {
        guard let lastAdmission else { return false }
        return ring.count > 0 && now >= lastAdmission && now <= lastAdmission + VisionAudioMailbox.ageLimit
    }

    mutating func append(_ samples: [Float], format: VisionAudioFormat,
                         work: VisionAudioMailbox.Work, now: TimeInterval) -> Bool {
        guard admits(work.ticket), mailbox.isFresh(work, now: now) else { return false }
        if ring.format != format {
            ring.configure(format)
            version &+= 1
            rendered = .waiting
        }
        guard ring.append(samples) else { return false }
        lastAdmission = now
        return true
    }

    mutating func render(ticket: VisionAudioTicket, version: UInt64,
                         frames: Int, now: TimeInterval, write: (Int, Int, Float) -> Void) {
        guard admits(ticket), self.version == version else { return }
        guard let lastAdmission, now >= lastAdmission, now <= lastAdmission + 0.150 else {
            ring.clear()
            rendered = .waiting
            return
        }
        var consumed = false
        for frame in 0..<frames {
            if ring.readFrame(into: { channel, value in write(frame, channel, value) }) { consumed = true }
        }
        rendered = consumed ? .rendering : .waiting
    }
}
