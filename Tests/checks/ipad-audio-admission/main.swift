import Foundation
import Network
import AVFoundation
import StreamProtocol

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
            var sends = 0
            #if ADMISSION
            client.audioAdmission.bind(ObjectIdentifier(peer))
            let ticket = client.audioAdmission.observe(catalog(yes), from: ObjectIdentifier(peer))!
            let gate = IPadMicrophoneFrameGate(admission: client.audioAdmission, send: { _,_,_ in sends += 1 })
            let player = PlaybackProbe(admission: client.audioAdmission)
            #else
            let gate = IPadMicrophoneFrameGate(send: { _,_,_ in sends += 1 })
            let player = PlaybackProbe()
            #endif
            let scope = MicrophoneScope(peer: UUID(), source: .desktop, inputGeneration: UUID(), videoEpoch: UUID(), destination: UUID(), capability: UUID())
            #if ADMISSION
            gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture, admission: ticket)
            #else
            gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture)
            #endif
            gate.emit(frame, captureID: capture)
            expect(sends == 1, "valid grant sends before revoke")
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
                expect(sends == 1, "network downgrade blocks actual send while main held")
                expect(engine.node.render().allSatisfy { $0 == 0 }, "network downgrade silences buffered render while main held")
                #if ADMISSION
                _ = client.audioAdmission.observe(catalog(yes), from: ObjectIdentifier(peer))
                gate.open(connection: peer, scope: scope, grant: UUID(), captureID: capture, admission: ticket)
                gate.emit(frame, captureID: capture)
                expect(sends == 1, "reallow cannot revive old grant or delayed open")
                expect(engine.node.render().allSatisfy { $0 == 0 }, "reallow cannot resurrect old buffered samples")
                #endif
            }
            player.stop()
        }
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
