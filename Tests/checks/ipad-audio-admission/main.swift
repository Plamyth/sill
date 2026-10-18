import Foundation
import Network
import AVFoundation
import StreamProtocol
import os

private var checks = 0
private var failures = 0
private func expect(_ value: Bool, _ name: String) {
    checks += 1
    if !value { failures += 1; print("FAIL \(name)") }
}
private func catalog(_ privacy: AudioPrivacyState?) -> WindowList {
    WindowList(macName: "Fixture", windows: [], active: .desktop, remoteAudio: 1, audioPrivacy: privacy)
}
private let yes = AudioPrivacyState(version: 2, protected: true)
private let frame = IPadMicrophonePCMFrame(sequence: 1, frameCount: 960, pcm: Data(repeating: 0, count: 1920))

@main struct Check {
    @MainActor static func main() async {
        for privacy: AudioPrivacyState? in [.init(version: 1, protected: true), .init(version: 99, protected: true), nil, .init(version: 2, protected: false)] {
            let client = ClientProbe()
            let peer = NWConnection(host: "127.0.0.1", port: 9991, using: .tcp)
            client.connection = peer
            let capture = UUID()
            let sent = OSAllocatedUnfairLock(initialState: 0)
            #if ADMISSION
            client.audioAdmission.bind(ObjectIdentifier(peer))
            let ticket = client.audioAdmission.observe(catalog(yes), from: ObjectIdentifier(peer))!
            let gate = IPadMicrophoneFrameGate(admission: client.audioAdmission, send: { _,_,_ in sent.withLock { $0 += 1 } })
            let player = PlaybackProbe(admission: client.audioAdmission)
            #else
            let gate = IPadMicrophoneFrameGate(send: { _,_,_ in sent.withLock { $0 += 1 } })
            let player = PlaybackProbe()
            #endif
            let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), destination: UUID(), capability: UUID())
            #if ADMISSION
            gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture, admission: ticket)
            #else
            gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture)
            #endif
            gate.emit(frame, captureID: capture)
            expect(sent.withLock { $0 } == 1, "valid grant sends before revoke")
            let packet = AudioPacket.packEncoded(sampleRate: 48000, channels: 1, cookie: Data(), packet: Data([1]))
            #if ADMISSION
            player.receive(packet, subscription: UUID(), admission: ticket) { _ in }
            #else
            player.receive(packet, subscription: UUID()) { _ in }
            #endif
            player.drainDecode()
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let engine = player.currentEngine else { fatalError("fixture engine missing") }
            expect(engine.node.render().contains { $0 != 0 }, "buffered production render is audible before revoke")
            DispatchQueue.global().sync {
                client.catalog(Wire.encode(catalog(privacy)), from: peer)
                gate.emit(frame, captureID: capture)
                expect(sent.withLock { $0 } == 1, "network downgrade blocks actual send while main held")
                expect(engine.node.render().allSatisfy { $0 == 0 }, "network downgrade silences buffered render while main held")
                #if ADMISSION
                _ = client.audioAdmission.observe(catalog(yes), from: ObjectIdentifier(peer))
                gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture, admission: ticket)
                gate.emit(frame, captureID: capture)
                expect(sent.withLock { $0 } == 1, "reallow cannot revive old grant or delayed open")
                expect(engine.node.render().allSatisfy { $0 == 0 }, "reallow cannot resurrect old buffered samples")
                #endif
            }
            player.stop()
        }
        #if ADMISSION
        await boundaries()
        await microphoneReplies()
        #endif
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
    #if ADMISSION
    @MainActor static func boundaries() async {
        let client = ClientProbe()
        let first = NWConnection(host: "127.0.0.1", port: 9991, using: .tcp)
        let second = NWConnection(host: "127.0.0.1", port: 9992, using: .tcp)
        let firstID = ObjectIdentifier(first), secondID = ObjectIdentifier(second)
        client.connection = first
        client.audioAdmission.bind(firstID)
        expect(client.audioAdmission.ticket(for: firstID) == nil, "new peer starts closed")
        for privacy: AudioPrivacyState? in [nil, .init(version: 1, protected: true), .init(version: 3, protected: true), .init(version: 2, protected: false)] {
            _ = client.audioAdmission.observe(catalog(privacy), from: firstID)
            expect(client.audioAdmission.ticket(for: firstID) == nil, "only fresh protected v2 admits media")
        }
        let old = client.audioAdmission.observe(catalog(yes), from: firstID)!
        expect(client.admitAudioCatalog(old), "current positive catalog accepted")
        expect(client.audioAdmission.observe(catalog(yes), from: firstID) == old, "duplicate positive catalog keeps live generation")
        let count = client.suspensions
        _ = client.admitAudioCatalog(old)
        expect(client.suspensions == count, "duplicate catalog does not retire current request")
        client.remoteAudioControl.setConnection(firstID)
        client.remoteAudioControl.receive(catalog(yes), from: firstID)
        client.remoteAudioControl.toggle()
        guard case .requesting(let oldRequest) = client.remoteAudioControl.status else { fatalError("missing request") }
        func header() -> StreamHeader {
            StreamMessage.parseHeader(StreamMessage(kind: .remoteAudioState, timestamp: 0, isKeyframe: false, payload: Data()).serialized())!
        }
        DispatchQueue.global().sync {
            client.catalog(Wire.encode(catalog(yes)), from: first)
            _ = client.receiveRemoteAudio(header(), Wire.encode(RemoteAudioState(enabled: true, requestID: oldRequest)), from: first)
            client.catalog(Wire.encode(catalog(.init(version: 1, protected: true))), from: first)
            client.catalog(Wire.encode(catalog(yes)), from: first)
            expect(!client.admitAudioCatalog(old), "old positive callback cannot reopen after downgrade and reallow")
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        expect(client.remoteAudioControl.status == .off, "latest main catalog retires old request even when downgrade main callback was skipped")
        _ = client.receiveRemoteAudio(header(), Wire.encode(RemoteAudioState(enabled: true, requestID: oldRequest)), from: first)
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(client.remoteAudioControl.status == .off, "old ACK cannot reactivate retired request")
        client.remoteAudioControl.toggle()
        guard case .requesting(let freshRequest) = client.remoteAudioControl.status else { fatalError("missing fresh request") }
        _ = client.receiveRemoteAudio(header(), Wire.encode(RemoteAudioState(enabled: true, requestID: freshRequest)), from: first)
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(client.remoteAudioControl.status == .starting(freshRequest), "fresh ACK in current generation can start")

        client.connection = second
        client.audioAdmission.bind(secondID)
        let fresh = client.audioAdmission.observe(catalog(yes), from: secondID)!
        expect(client.audioAdmission.observe(catalog(nil), from: firstID) == nil, "old peer downgrade ignored")
        expect(client.audioAdmission.ticket(for: secondID) == fresh, "old peer cannot close newer peer")
        expect(!client.audioAdmission.isCurrent(old), "old peer callbacks invalidated")
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let gate = IPadMicrophoneFrameGate(admission: client.audioAdmission, send: { _,_,_ in sent.withLock { $0 += 1 } })
        let capture = UUID()
        let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), destination: UUID(), capability: UUID())
        gate.open(connection: first, scope: scope, grant: UUID(), captureID: capture, admission: fresh)
        gate.emit(frame, captureID: capture)
        expect(sent.withLock { $0 } == 0, "ticket cannot be used on another connection")
        gate.open(connection: second, scope: scope, grant: UUID(), captureID: capture, admission: fresh)
        gate.open(connection: first, scope: scope, grant: UUID(), captureID: UUID(), admission: old)
        gate.emit(frame, captureID: capture)
        expect(sent.withLock { $0 } == 1, "delayed old-peer open cannot replace newer grant")

        let player = PlaybackProbe(admission: client.audioAdmission)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        holdAudioDecode(entered, release)
        let packet = AudioPacket.packEncoded(sampleRate: 48000, channels: 1, cookie: Data(), packet: Data([1]))
        player.receive(packet, subscription: UUID(), admission: fresh) { _ in }
        let decoding = DispatchQueue.global().sync { entered.wait(timeout: .now() + 3) == .success }
        expect(decoding, "production decode paused before append")
        _ = client.audioAdmission.observe(catalog(nil), from: secondID)
        _ = client.audioAdmission.observe(catalog(yes), from: secondID)
        release.signal()
        player.drainDecode()
        expect(player.buffered == 0, "delayed old decode cannot refill after revoke and reallow")
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(player.currentEngine == nil, "delayed old engine callback cannot start")
        holdAudioDecode(DispatchSemaphore(value: 0), DispatchSemaphore(value: 1))
        let latest = client.audioAdmission.ticket(for: secondID)!
        player.receive(packet, subscription: UUID(), admission: latest) { _ in }
        player.drainDecode()
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(player.currentEngine?.node.render().contains { $0 != 0 } == true, "fresh generation can render new samples")
        player.stop()
    }

    @MainActor static func microphoneReplies() async {
        let client = ClientProbe()
        let peer = NWConnection(host: "127.0.0.1", port: 9993, using: .tcp)
        let id = ObjectIdentifier(peer)
        client.connection = peer
        client.audioAdmission.bind(id)
        let generation = UUID()
        let list = WindowList(macName: "fixture", windows: [], active: .desktop, remoteAudio: 1,
            inputGeneration: generation.uuidString,
            videoEpoch: VideoEpoch(generation: generation.uuidString, source: .desktop,
                geometry: .init(x: 0, y: 0, width: 10, height: 10), width: 10, height: 10),
            microphone: .init(peer: UUID(), destination: UUID(), generation: UUID()), audioPrivacy: yes)
        _ = client.audioAdmission.observe(list, from: id)
        _ = client.microphonePolicy.setConnection(id)
        _ = client.microphonePolicy.observe(list, from: id)
        _ = client.microphonePolicy.toggle()
        let request = client.microphonePolicy.startRequestID!, scope = client.microphonePolicy.scope!
        _ = client.microphonePolicy.permissionResolved(true, requestID: request, scope: scope, from: id)
        func header() -> StreamHeader {
            StreamMessage.parseHeader(StreamMessage(kind: .microphoneState, timestamp: 0, isKeyframe: false, payload: Data()).serialized())!
        }
        let active = MicrophoneState(requestID: request, scope: scope, phase: .active, grantID: UUID())
        DispatchQueue.global().sync {
            _ = client.receiveMicrophone(header(), Wire.encode(active), from: peer)
            var revoked = list; revoked.audioPrivacy = nil
            _ = client.audioAdmission.observe(revoked, from: id)
            _ = client.audioAdmission.observe(list, from: id)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(client.grants == 0, "queued old microphone grant cannot begin capture after reallow")
        _ = client.microphonePolicy.backgrounded()
        var revoked = list; revoked.audioPrivacy = nil
        _ = client.audioAdmission.observe(revoked, from: id)
        let off = MicrophoneState(requestID: client.microphonePolicy.stopRequestID!, scope: scope, phase: .off, grantID: nil)
        _ = client.receiveMicrophone(header(), Wire.encode(off), from: peer)
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(client.microphonePolicy.phase == .off, "matching cleanup ACK is accepted while privacy admission is closed")
        _ = client.audioAdmission.observe(list, from: id)
        _ = client.microphonePolicy.toggle()
        let fresh = client.microphonePolicy.startRequestID!
        _ = client.microphonePolicy.permissionResolved(true, requestID: fresh, scope: scope, from: id)
        _ = client.receiveMicrophone(header(), Wire.encode(MicrophoneState(requestID: fresh, scope: scope, phase: .active, grantID: UUID())), from: peer)
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(client.grants == 1, "fresh matching microphone grant can begin capture")
    }
    #endif

}
