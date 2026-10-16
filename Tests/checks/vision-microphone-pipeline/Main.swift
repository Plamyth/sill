import AVFoundation
import Foundation
import Network
import StreamProtocol

@MainActor var assertions = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !value() { print("FAIL \(name)"); exit(1) }
}
@MainActor func until(_ predicate: () -> Bool, _ name: String) async {
    for _ in 0..<2000 {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    expect(false, name)
}
@MainActor final class Owner: HostMicrophoneOriginalOwner {
    var grant: HostLocalOwnerGrant?
    func microphoneGrant(peer: UUID, source: StreamSource, inputGeneration: UUID,
                         videoEpoch: UUID, fingerprint: Data) -> HostLocalOwnerGrant? { grant }
}
@MainActor final class Sink: HostMicrophoneSink {
    func close() async -> String? { nil }
    func runtimeValid() -> Bool { true }
}
@MainActor final class Pipeline {
    let connection = NWConnection()
    let client = StreamClient()
    let owner = Owner()
    let sink = Sink()
    var receiver: HostMicrophoneReceiver!
    var host: CoordinatorHarness!
    let reader = ReaderHarness()
    var readerClient: ReaderHarness.Client!
    var render: MicrophoneRenderBuffer!
    var states: [MicrophoneState] = []
    var clock = DispatchTime.now().uptimeNanoseconds
    var outputCursor = 0
    var replyCursor = 0
    var inputSample: Int64 = 0
    var ordinary = 0
    var sequence = 0

    init() {
        receiver = HostMicrophoneReceiver(provider: owner, automaticWatchdog: false,
            now: { [unowned self] in self.clock }, prepare: { [unowned self] _, render in
                self.render = render
                return HostMicrophonePreparation(resource: self.sink, error: nil)
            })
        host = CoordinatorHarness(receiver)
        let paired = PairHarness()
        paired.paired = [PairedFixture(fingerprint: "fixture", fingerprintData: Data([1]))]
        host.remote = paired
        host.installTrustHook()
        let peer = host.microphoneIngress.authorize(connection, fingerprint: Data([1]))!
        host.connections[ObjectIdentifier(connection)] = connection
        host.routes[ObjectIdentifier(connection)] = .home(.loopback,
            peer: ClientRoute.Peer(fingerprint: Data([1]), name: nil, cableDevice: nil))
        let generation = UUID()
        host.inputGeneration = generation.uuidString
        host.videoEpoch = VideoEpoch(generation: generation.uuidString, source: .desktop,
            geometry: .init(x: 0, y: 0, width: 1, height: 1), width: 1, height: 1)
        let scope = MicrophoneScope(peer: peer.id, source: .desktop, inputGeneration: generation,
            videoEpoch: host.videoEpoch!.id, destination: UUID(), capability: UUID())
        owner.grant = HostLocalOwnerGrant(owner: UUID(), callGeneration: UUID(), scope: scope,
            fingerprint: Data([1]), destination: HostMicrophoneDestination(outputUID: "inert.output",
                inputUID: "inert.input", pluginBundleID: "inert.plugin", outputChannels: 1,
                inputChannels: 1, outputChannel: 0, inputChannel: 0)!,
            expiresAt: clock + 30_000_000_000)
        receiver.sendState = { [unowned self] state, render in
            self.states.append(state)
            let message = StreamMessage(kind: .microphoneState, timestamp: 0,
                                        isKeyframe: false, payload: Wire.encode(state))
            self.reader.sendMicrophone(message, to: self.connection, render: render)
        }
        receiver.sendReceipt = { [unowned self] receipt in
            let message = StreamMessage(kind: .microphoneReceipt, timestamp: 0,
                                        isKeyframe: false, payload: Wire.encode(receipt))
            self.reader.sendMicrophone(message, to: self.connection, render: nil)
        }
        readerClient = ReaderHarness.Client(connection)
        readerClient.route = host.routes[ObjectIdentifier(connection)]!
        reader.clients[ObjectIdentifier(connection)] = readerClient
        reader.onMessage = { [unowned self] _, _ in self.ordinary += 1 }
        reader.onMicrophoneMessage = { [unowned self] message, connection in
            self.host.microphoneIngress.offer(message, from: connection, now: self.clock)
        }
        client.connection = connection
        client.microphoneSetConnection(connection)
        let list = Wire.decode(WindowList.self, from: host.microphoneCatalog(to: connection).payload)!
        expect(list.microphone != nil, "actual host advertises exact inert owner grant")
        client.microphoneObserve(list, from: connection)
    }

    func clientMessages() -> [Data] {
        let sent = connection.sent
        let fresh = Array(sent.dropFirst(outputCursor))
        outputCursor = sent.count
        return fresh.filter {
            let kind = StreamMessage.parseHeader($0)?.kind
            return kind == .microphoneControl || kind == .microphoneFrame
        }
    }
    func deliverReplies() {
        let sent = connection.sent
        for bytes in sent.dropFirst(replyCursor) {
            guard let header = StreamMessage.parseHeader(bytes),
                  header.kind == .microphoneState || header.kind == .microphoneReceipt else { continue }
            _ = client.receiveMicrophone(header, Data(bytes.dropFirst(StreamMessage.headerLength)), from: connection)
        }
        replyCursor = sent.count
    }
    func feed(_ batches: [Data]) {
        for batch in batches {
            var rest = batch
            while !rest.isEmpty {
                guard let header = StreamMessage.parseHeader(rest),
                      rest.count >= StreamMessage.headerLength + header.payloadLength else {
                    expect(false, "complete actual client wire frames"); return
                }
                let count = StreamMessage.headerLength + header.payloadLength
                connection.inbound += [Data(rest.prefix(StreamMessage.headerLength)),
                    Data(rest[StreamMessage.headerLength..<count])]
                rest = Data(rest.dropFirst(count))
            }
        }
        reader.receiveLoop(readerClient)
    }
    func produce(packets: Int) async -> [Data] {
        let previous = connection.sent.count
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packets * 960))!
        buffer.frameLength = buffer.frameCapacity
        for packet in 0..<packets {
            for sample in 0..<960 {
                buffer.floatChannelData![0][packet * 960 + sample] = Float(sequence + packet + 1) / 128
            }
        }
        sequence += packets
        VisionAudioSharedHardware.graph.input?.copyInput(buffer,
            AVAudioTime(sampleTime: inputSample, atRate: 48_000))
        inputSample += Int64(packets * 960)
        await until({ self.connection.sent.count > previous }, "actual converter emits new hardware batch")
        let result = clientMessages()
        expect(result.count == 1 && StreamMessage.parseHeader(result[0])?.kind == .microphoneFrame,
               "one hardware batch is one framed send")
        return result
    }
    func pull(_ count: Int, time: UInt64) -> [Int16] {
        var result = [Int16](repeating: 0, count: count)
        render.render(frames: count, now: time) { result[$0] = $1 }
        return result
    }
}

@main struct Check {
    @MainActor static func main() async {
        let p = Pipeline()
        expect(permissionRequests.withLock { $0 == 0 }, "catalog does not request microphone permission")
        p.client.toggleVisionMicrophone()
        let start = p.clientMessages()
        expect(start.count == 1, "actual client sends one start")
        p.feed(start); p.host.drainMicrophoneIngress()
        await until({ p.deliverReplies(); return p.client.microphonePhase == .live },
                    "actual host state enables actual client capture")
        expect(p.receiver.phase == .active && permissionRequests.withLock { $0 == 1 }, "one permission follows host grant")

        for burst in 0..<3 {
            p.clock += 100_000_000
            let bytes = await p.produce(packets: 5)
            p.feed(bytes); p.host.drainMicrophoneIngress()
            for packet in 0..<5 {
                let samples = p.pull(960, time: p.clock + 50_000_000 + UInt64(packet) * 20_000_000)
                expect(samples.allSatisfy { $0 == Int16((burst * 5 + packet + 1) * 256) },
                       "continuous actual client burst preserves ordered PCM")
            }
        }
        expect(p.render.counters.0 == 14_400 && p.host.microphoneIngress.overflowCount == 0 &&
               p.render.counters.2 == 0 && p.ordinary == 0, "continuous burst counts and authenticated dispatch")

        p.clock += 100_000_000
        p.feed(await p.produce(packets: 5)); p.host.drainMicrophoneIngress()
        var partial: [Int16] = []
        for count in [137, 960, 960, 960, 960, 823] {
            partial += p.pull(count, time: p.clock + 50_000_000)
        }
        let expected = (16...20).flatMap { [Int16](repeating: Int16($0 * 256), count: 960) }
        expect(partial == expected, "partial pulls cross actual client packet boundaries without loss")

        p.clock += 100_000_000
        let overflow = await p.produce(packets: 10)
        p.feed(overflow)
        expect(p.host.microphoneIngress.overflowCount == 4, "ingress overflow counts oldest actual packets")
        p.host.drainMicrophoneIngress()
        for sequence in 25...30 {
            expect(p.pull(960, time: p.clock + 50_000_000).allSatisfy { $0 == Int16(sequence * 256) },
                   "ingress overflow retains newest six in order")
        }

        p.clock += 100_000_000
        p.feed(await p.produce(packets: 5)); p.host.drainMicrophoneIngress()
        p.feed(await p.produce(packets: 5)); p.host.drainMicrophoneIngress()
        expect(p.render.counters.2 == 4, "render overflow counts oldest actual packets")
        for sequence in 35...40 {
            expect(p.pull(960, time: p.clock + 50_000_000).allSatisfy { $0 == Int16(sequence * 256) },
                   "render overflow retains newest six in order")
        }

        p.clock += 100_000_000
        p.feed(await p.produce(packets: 5)); p.host.drainMicrophoneIngress()
        expect(p.pull(960, time: p.clock + 160_000_000).allSatisfy { $0 == 41 * 256 },
               "actual queued packet remains valid at exact160ms boundary")
        expect(p.pull(960, time: p.clock + 160_000_001).allSatisfy { $0 == 0 } &&
               p.render.counters.2 == 8, "expired actual burst is silent and fully counted")
        p.clock += 200_000_000
        let final = await p.produce(packets: 5)
        p.feed(final); p.host.drainMicrophoneIngress()
        p.client.toggleVisionMicrophone()
        let stop = p.clientMessages()
        p.feed(stop)
        expect(!p.render.isOpen && p.pull(960, time: p.clock).allSatisfy { $0 == 0 },
               "actual stop revokes queued render before actor drain")
        p.host.drainMicrophoneIngress()
        await until({ p.receiver.phase == .off }, "host stop cleanup finishes")
        p.feed(final); p.host.drainMicrophoneIngress()
        expect(p.pull(960, time: p.clock).allSatisfy { $0 == 0 }, "late exact old grant cannot render after stop")
        expect(p.client.microphoneCapture == nil && VisionAudioSharedHardware.shared.cleanupProblem == nil,
               "actual capture cleanup leaves no shared graph owner")
        print("RESULT_ASSERTIONS \(assertions)")
    }
}
