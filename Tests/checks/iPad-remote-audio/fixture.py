from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_platform import select_platform

root = Path(sys.argv[1])
out = Path(sys.argv[2])
client = select_platform((root / 'iOSClient/StreamClient.swift').read_text(), vision=False)
adapter = select_platform((root / 'iOSClient/StreamClient+Audio.swift').read_text(), vision=False)

def body_after(marker):
    start = client.index(marker)
    brace = client.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (client[end] == '{') - (client[end] == '}')
        end += 1
    return client[start:end]

properties = client[client.index('    private let remoteAudio ='):client.index('    // Connection. The setters')]
properties = properties.replace('@Published private(set) ', '')
connection = body_after('    var connection: NWConnection?')
fixture = '''import Foundation
import StreamProtocol

final class RemoteAudioPlayer {
    var packets: [Data] = []
    var stops = 0
    func receive(_ packet: Data) { packets.append(packet) }
    func stop() { stops += 1 }
}
final class NWConnection {
    enum Completion { case contentProcessed((Error?) -> Void) }
    var writes: [Data] = []
    func send(content: Data?, completion: Completion) {
        if let content { writes.append(content) }
        if case .contentProcessed(let done) = completion { done(nil) }
    }
}
final class SessionLink { var connection: NWConnection? }
final class StreamClient {
    private let link = SessionLink()
    func microphoneBackgrounded() {}
'''
fixture += properties.replace('    private let remoteAudio', '    let remoteAudio')
fixture += connection + '''
    func connectionLost(_ peer: NWConnection, error: Error) {
        if connection === peer { connection = nil }
    }
}
'''
fixture += adapter.replace('import Network\n', '')
screen = (root / 'iOSClient/StreamScreen.swift').read_text()
marker = '.onChange(of: scenePhase) { _, phase in'
start = screen.index(marker) + len(marker)
depth = 1
end = start
while depth:
    depth += (screen[end] == '{') - (screen[end] == '}')
    end += 1
scene_body = screen[start:end - 1]
fixture += '''
enum ScenePhase { case active, inactive, background }
@MainActor final class SceneHarness {
    let client: StreamClient
    var scaleOpen = true
    var windowMenu: Int? = 1
    init(client: StreamClient) { self.client = client }
    func changed(_ phase: ScenePhase) {
''' + scene_body + '''
    }
}
'''
(out / 'ClientFixture.swift').write_text(fixture)

checks = {
    'actual origin is passed at delivery': 'handle(header, data, from: c)',
    'kept messages retain origin': 'self.deliver(m.header, m.payload, from: c)',
    'audio adapter is called by handle': 'if receiveRemoteAudio(header, data, from: peer) { return }',
    'window lists retain origin': 'let from: NWConnection? = peer',
    'window lists update capability and source': 'self.remoteAudioControl.receive(list, from: ObjectIdentifier(peer))',
    'source selection revokes before send': 'private func request(_ source: StreamSource) {\n        remoteAudioControl.sourceWillChange()',
    'teardown clears consent': 'remoteAudioControl.setConnection(nil)',
    'handover clears consent': 'remoteAudioControl.setConnection(ObjectIdentifier(c))',
}
for name, needle in checks.items():
    assert needle in client, name
assert 'remoteAudio.receive(data)' not in client
panel = (root / 'iOSClient/HostSettingsPanel.swift').read_text()
assert 'IPadRemoteAudioControl(client: client)' in panel
assert '.disabled(!client.remoteAudioStatus.available)' in (root / 'iOSClient/StreamScreen.swift').read_text()
print(f'PASS {len(checks) + 3} supplementary integration checks')
