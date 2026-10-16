import Foundation
import StreamProtocol

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { fatalError("FAIL \(name)") }
}

private func list(_ capability: Int? = 1, source: StreamSource = .desktop) -> WindowList {
    WindowList(macName: "Test Mac", windows: [], active: source, remoteAudio: capability)
}

private func header(_ kind: StreamMessageKind) -> StreamHeader {
    StreamMessage.parseHeader(StreamMessage(kind: kind, timestamp: 0, isKeyframe: false, payload: Data()).serialized())!
}

private func waitForDecoder(_ entered: DispatchSemaphore) -> Bool {
    entered.wait(timeout: .now() + 3) == .success
}

private final class Probe {
    let peer = NWConnection()
    let other = NWConnection()
    var requests: [(ObjectIdentifier, RemoteAudioSubscription)] = []
    var stops = 0
    var played: [Data] = []
    var updates: [IPadRemoteAudioController.Status] = []
    lazy var control = IPadRemoteAudioController(
        send: { [unowned self] in requests.append(($0, $1)) },
        stop: { [unowned self] in stops += 1 },
        play: { [unowned self] in played.append($0) },
        changed: { [unowned self] in updates.append($0) })
    var id: ObjectIdentifier { ObjectIdentifier(peer) }
    var otherID: ObjectIdentifier { ObjectIdentifier(other) }
    var last: RemoteAudioSubscription { requests.last!.1 }
    func connect() { control.setConnection(id) }
    func available() { connect(); control.receive(list(), from: id) }
    func ack(_ request: RemoteAudioSubscription, from origin: ObjectIdentifier? = nil) {
        control.receive(RemoteAudioState(enabled: request.enabled, requestID: request.requestID), from: origin ?? id)
    }
    func packet(from origin: ObjectIdentifier? = nil) { control.receiveAudio(Data([33]), from: origin ?? id) }
}

@main
struct Check {
    @MainActor static func main() async {
        capability()
        consent()
        revocation()
        timeout()
        await transport()
        await backgroundLifecycle()
        await playback()
        print("PASS \(checks) iPad audio behavior assertions")
    }

    static func capability() {
        let p = Probe()
        p.control.toggle()
        expect(p.requests.isEmpty, "no peer cannot subscribe")
        p.connect()
        for value: Int? in [nil, 0, 2, -1] {
            p.control.receive(list(value), from: p.id)
            p.control.toggle()
            p.packet()
            expect(p.control.status == .unavailable, "only version 1 is supported")
            expect(p.requests.isEmpty && p.played.isEmpty, "unsupported host gets no audio effects")
        }
        p.control.receive(list(), from: p.otherID)
        expect(p.control.status == .unavailable, "old peer cannot advertise capability")
        p.control.receive(list(), from: p.id)
        expect(p.control.status == .off, "capability starts off")
        p.packet()
        expect(p.played.isEmpty && p.requests.isEmpty, "advertisement is not consent")
    }

    static func consent() {
        let p = Probe()
        p.available()
        p.control.toggle()
        let on = p.last
        expect(on.enabled && p.requests.count == 1, "tap sends one ON")
        expect(p.control.status == .requesting(on.requestID), "ON awaits ACK")
        p.packet()
        expect(p.played.isEmpty, "pre ACK packets are discarded")
        p.control.receive(RemoteAudioState(enabled: true, requestID: nil), from: p.id)
        p.control.receive(RemoteAudioState(enabled: true, requestID: UUID()), from: p.id)
        p.ack(on, from: p.otherID)
        expect(p.control.status == .requesting(on.requestID), "nil wrong UUID and old peer cannot enable")
        p.ack(on)
        p.packet(from: p.otherID)
        expect(p.played.isEmpty, "audio must come from current peer")
        p.packet()
        expect(p.played == [Data([33])], "matching ACK admits current peer packet")
        let before = p.stops
        p.control.toggle()
        let off = p.last
        expect(!off.enabled && off.requestID != on.requestID, "OFF has its own UUID")
        expect(p.stops == before + 1 && p.control.status == .off, "OFF stops synchronously")
        p.ack(on)
        p.packet()
        expect(p.played.count == 1, "old ON after OFF cannot play")
        p.control.toggle()
        let second = p.last
        expect(second.requestID != on.requestID && second.requestID != off.requestID, "new ON is a new action")
        p.ack(off)
        expect(p.control.status == .requesting(second.requestID), "stale OFF cannot revoke new ON")
        p.ack(second)
        p.control.receive(RemoteAudioState(enabled: false, requestID: on.requestID), from: p.id)
        expect(p.control.status == .listening(second.requestID), "old refusal cannot revoke current consent")
        p.control.receive(RemoteAudioState(enabled: false, requestID: nil, reason: "Source changed"), from: p.id)
        expect(p.control.status == .failed("Source changed"), "host revocation stops playback")
        p.ack(second)
        p.packet()
        expect(p.played.count == 1, "revoked ACK cannot grant again")
        p.control.toggle()
        p.control.toggle()
        expect(!p.last.enabled && p.last.requestID != off.requestID, "each OFF has a fresh action ID")
    }

    static func revocation() {
        for pending in [true, false] {
            for event in 0..<4 {
                let p = Probe()
                p.available()
                p.control.toggle()
                let on = p.last
                if !pending { p.ack(on) }
                let before = p.stops
                switch event {
                case 0: p.control.sourceWillChange()
                case 1: p.control.receive(list(source: .window(42)), from: p.id)
                case 2: p.control.receive(list(nil), from: p.id)
                default: p.control.setConnection(nil)
                }
                expect(p.stops == before + 1, "boundary immediately stops pending or playing audio")
                expect(!p.last.enabled && p.last.requestID != on.requestID, "boundary sends separate OFF")
                p.ack(on)
                p.packet()
                expect(p.played.isEmpty && !p.control.status.requested, "boundary discards old ACK and audio")
            }
        }
        let p = Probe()
        p.available()
        p.control.toggle()
        let on = p.last
        p.control.setConnection(p.otherID)
        expect(p.control.status == .unavailable, "replacement clears capability")
        expect(p.requests.last!.0 == p.id && !p.last.enabled, "replacement revokes original peer")
        p.control.receive(list(), from: p.otherID)
        p.control.toggle()
        let next = p.last
        p.ack(on)
        p.ack(next)
        p.packet()
        expect(p.played.isEmpty, "replaced peer cannot grant or play")
        p.ack(next, from: p.otherID)
        p.packet(from: p.otherID)
        expect(p.played.count == 1, "replacement requires fresh tap and ACK")
        p.control.receive(list(), from: p.otherID)
        expect(p.control.status == .listening(next.requestID), "repeated list preserves same source consent")
    }

    static func timeout() {
        let p = Probe()
        p.available()
        p.control.toggle()
        let on = p.last
        p.control.expire(UUID(), from: p.id)
        p.control.expire(on.requestID, from: p.otherID)
        expect(p.control.status == .requesting(on.requestID), "wrong deadline cannot expire consent")
        p.control.expire(on.requestID, from: p.id)
        expect(!p.last.enabled && !p.control.status.requested, "timeout revokes host subscription")
        p.ack(on)
        p.packet()
        expect(p.played.isEmpty, "late ACK after timeout stays silent")
        p.control.toggle()
        let next = p.last
        p.ack(next)
        p.control.expire(next.requestID, from: p.id)
        expect(p.control.status == .listening(next.requestID), "ACK before deadline cancels timeout effect")
        p.control.receive(RemoteAudioState(enabled: false, requestID: next.requestID, reason: "Capture failed"), from: p.id)
        expect(p.control.status == .failed("Capture failed"), "matching refusal is visible")
    }

    @MainActor static func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor static func transport() async {
        let c = StreamClient()
        let old = NWConnection()
        let next = NWConnection()
        c.connection = old
        c.remoteAudioControl.receive(list(), from: ObjectIdentifier(old))
        c.toggleRemoteAudio()
        expect(old.writes.count == 1, "connected supported client sends a subscription after tap")
        let message = old.writes.last!
        expect(StreamMessage.parseHeader(message)?.kind == .remoteAudioControl, "actual adapter sends kind200")
        let on = Wire.decode(RemoteAudioSubscription.self, from: message.subdata(in: 14..<message.count))!
        expect(on.enabled, "transport payload is ON")
        expect(!c.receiveRemoteAudio(header(.frame), Data(), from: old), "audio adapter leaves video route alone")
        expect(c.receiveRemoteAudio(header(.audio), Data([1]), from: old), "audio route consumes kind33")
        await drain()
        expect(c.remoteAudio.packets.isEmpty, "adapter rejects audio before ACK")
        _ = c.receiveRemoteAudio(header(.remoteAudioState), Wire.encode(RemoteAudioState(enabled: true, requestID: on.requestID)), from: old)
        _ = c.receiveRemoteAudio(header(.audio), Data([2]), from: old)
        await drain()
        expect(c.remoteAudio.packets == [Data([2])], "adapter processes ACK before following audio")
        _ = c.receiveRemoteAudio(header(.audio), Data([3]), from: old)
        c.toggleRemoteAudio()
        let offData = old.writes.last!
        let off = Wire.decode(RemoteAudioSubscription.self, from: offData.subdata(in: 14..<offData.count))!
        expect(!off.enabled && off.requestID != on.requestID, "actual transport sends distinct OFF")
        await drain()
        expect(c.remoteAudio.packets.count == 1, "OFF beats already enqueued packet")
        c.toggleRemoteAudio()
        let queued = old.writes.last!
        let queuedOn = Wire.decode(RemoteAudioSubscription.self, from: queued.subdata(in: 14..<queued.count))!
        _ = c.receiveRemoteAudio(header(.remoteAudioState), Wire.encode(RemoteAudioState(enabled: true, requestID: queuedOn.requestID)), from: old)
        c.connection = next
        await drain()
        expect(c.remoteAudioStatus == .unavailable, "connection setter rejects enqueued old ACK")
        expect(next.writes.isEmpty, "old consent does not migrate to next connection")
        c.remoteAudioControl.receive(list(), from: ObjectIdentifier(next))
        c.toggleRemoteAudio()
        let nextMessage = next.writes.last!
        let newOn = Wire.decode(RemoteAudioSubscription.self, from: nextMessage.subdata(in: 14..<nextMessage.count))!
        _ = c.receiveRemoteAudio(header(.remoteAudioState), Data([0xff]), from: next)
        _ = c.receiveRemoteAudio(header(.remoteAudioState), Wire.encode(RemoteAudioState(enabled: true, requestID: newOn.requestID)), from: old)
        await drain()
        expect(c.remoteAudioStatus == .requesting(newOn.requestID), "malformed and old peer ACKs stay pending")
        _ = c.receiveRemoteAudio(header(.remoteAudioState), Wire.encode(RemoteAudioState(enabled: true, requestID: newOn.requestID)), from: next)
        _ = c.receiveRemoteAudio(header(.audio), Data([4]), from: next)
        await drain()
        expect(c.remoteAudio.packets == [Data([2]), Data([4])], "fresh connection tap and ACK restores playback")
        let stops = c.remoteAudio.stops
        c.connection = nil
        expect(c.remoteAudio.stops == stops + 1 && c.remoteAudioStatus == .unavailable, "disconnect stops synchronously")
        _ = c.receiveRemoteAudio(header(.audio), Data([5]), from: next)
        await drain()
        expect(c.remoteAudio.packets.count == 2, "post disconnect packet is silent")
    }

    @MainActor static func backgroundLifecycle() async {
        let c = StreamClient()
        let peer = NWConnection()
        c.connection = peer
        c.remoteAudioControl.receive(list(), from: ObjectIdentifier(peer))
        c.toggleRemoteAudio()
        let on = c.remoteAudioControl.status
        guard case .requesting(let id) = on else { fatalError("expected pending ON") }
        _ = c.receiveRemoteAudio(header(.remoteAudioState),
            Wire.encode(RemoteAudioState(enabled: true, requestID: id)), from: peer)
        await drain()
        expect(c.remoteAudioStatus == .listening(id), "matching ACK enables before background")
        let screen = SceneHarness(client: c)
        let stops = c.remoteAudio.stops
        screen.changed(.background)
        expect(!screen.scaleOpen && screen.windowMenu == nil, "background still dismisses transient UI")
        expect(c.remoteAudioStatus == .off && c.remoteAudio.stops == stops + 1,
               "background immediately revokes playing consent")
        let off = Wire.decode(RemoteAudioSubscription.self,
            from: peer.writes.last!.subdata(in: 14..<peer.writes.last!.count))!
        expect(!off.enabled && off.requestID != id, "background sends distinct OFF to original peer")
        _ = c.receiveRemoteAudio(header(.remoteAudioState),
            Wire.encode(RemoteAudioState(enabled: true, requestID: id)), from: peer)
        _ = c.receiveRemoteAudio(header(.audio), Data([1]), from: peer)
        await drain()
        expect(c.remoteAudio.packets.isEmpty, "late ACK and packet cannot resume background audio")

        let pendingClient = StreamClient()
        let pendingPeer = NWConnection()
        pendingClient.connection = pendingPeer
        pendingClient.remoteAudioControl.receive(list(), from: ObjectIdentifier(pendingPeer))
        pendingClient.toggleRemoteAudio()
        guard case .requesting(let pendingID) = pendingClient.remoteAudioStatus else {
            fatalError("expected pending background request")
        }
        let pendingScreen = SceneHarness(client: pendingClient)
        pendingScreen.changed(.inactive)
        expect(pendingClient.remoteAudioStatus == .off, "inactive phase revokes pending ON")
        let pendingOFF = Wire.decode(RemoteAudioSubscription.self,
            from: pendingPeer.writes.last!.subdata(in: 14..<pendingPeer.writes.last!.count))!
        expect(!pendingOFF.enabled && pendingOFF.requestID != pendingID,
               "inactive phase sends distinct OFF for pending ON")
        _ = pendingClient.receiveRemoteAudio(header(.remoteAudioState),
            Wire.encode(RemoteAudioState(enabled: true, requestID: pendingID)), from: pendingPeer)
        pendingScreen.changed(.active)
        await drain()
        expect(pendingClient.remoteAudioStatus == .off && pendingPeer.writes.count == 2,
               "foreground return does not reuse background consent")
    }

    @MainActor static func playback() async {
        let player = PlaybackProbe()
        let samples = Array(repeating: Int16(1000), count: 2400)
        let packet = samples.withUnsafeBufferPointer { AudioPacket.pack(sampleRate: 48000, channels: 1, samples: $0) }
        let releases = AVAudioSession.shared.releases
        player.stop()
        expect(AVAudioSession.shared.releases == releases, "inactive player leaves other audio sessions alone")
        player.receive(packet)
        player.drainDecode()
        await drain()
        expect(player.buffered == 2400 && player.currentEngine != nil, "production receive and append buffer valid PCM")
        let oldEngine = player.currentEngine!
        player.stop()
        expect(oldEngine.stopped && player.currentEngine == nil, "production OFF stops engine before returning")
        expect(player.buffered == 0, "production OFF clears buffered samples")
        expect(AVAudioSession.shared.releases == releases + 1, "owned session is released immediately")

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        holdAudioDecode(entered, release)
        player.receive(AudioPacket.packEncoded(sampleRate: 48000, channels: 1, cookie: Data(), packet: Data([1])))
        let decodingStarted = await Task.detached { waitForDecoder(entered) }.value
        expect(decodingStarted, "encoded packet reaches the deterministic decoder barrier")
        player.stop()
        release.signal()
        player.drainDecode()
        await drain()
        expect(player.buffered == 0 && player.currentEngine == nil, "decode finishing after OFF cannot refill or restart")

        player.receive(packet)
        player.drainDecode()
        await drain()
        expect(player.buffered == 2400 && player.currentEngine != nil, "fresh playback can start after old decode drains")
        let nextEngine = player.currentEngine!
        player.stop()
        player.receive(packet)
        player.drainDecode()
        await drain()
        expect(nextEngine.stopped && player.currentEngine != nil, "old queued stop cannot tear down a fresh engine")
        expect(player.buffered == 2400, "fresh lease contains only fresh samples")
        player.stop()
    }
}
