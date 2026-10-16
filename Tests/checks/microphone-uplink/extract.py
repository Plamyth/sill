"""Copy production units and exact boundary bodies; replace external connections only."""
import hashlib
from pathlib import Path


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def fixture(root):
    root = Path(root).resolve()
    here = root / 'Tests/checks/microphone-uplink'
    paths = ['Sources/StreamProtocol/' + name + '.swift' for name in
             ['StreamMessage', 'Switcher', 'MicrophoneUplink', 'Viewport', 'Compatibility', 'Input', 'Pointer', 'SafeText']]
    paths += ['Sources/SillHost/' + name + '.swift' for name in
              ['HostMicrophoneGrant', 'HostMicrophoneReceiver', 'HALMicrophoneSink', 'MicrophoneIngress', 'PointerControl']]
    files = {name: (root / name).read_text() for name in paths}
    for name in ['Network.swift', 'FakeHAL.swift', 'Main.swift']:
        files[name] = (here / name).read_text()
    server = (root / 'Sources/SillHost/StreamServer.swift').read_text()
    coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
    remote = (root / 'Sources/SillHost/RemoteAccess.swift').read_text()
    pieces = {
        'ROUTE': block(server, 'enum ClientRoute:'),
        'READER': block(server, 'private func receiveLoop('),
        'EGRESS': block(server, 'func sendMicrophone('),
        'PAIRED': block(remote, 'func isPaired('),
        'REMOVE': block(remote, 'package func remove('),
        'EPOCH': block(coordinator, 'private var videoEpoch:'),
        'CURRENT': block(coordinator, 'private func microphoneScopeIsCurrent('),
        'CONNECTION': block(coordinator, 'private func microphoneConnection('),
        'DRAIN': block(coordinator, 'private func drainMicrophoneIngress('),
        'CATALOG': block(coordinator, 'private func microphoneCatalog('),
        'TRUSTHOOK': block(coordinator, 'remote?.onMicrophoneTrustRevoked ='),
    }
    disconnect = block(coordinator, 'server.onClientDisconnected =')
    immediate = disconnect[disconnect.index('            let microphonePeer'):disconnect.index('            Task {')]
    cleanup = block(disconnect, 'if let microphonePeer {')
    pieces['DISCONNECT'] = 'func disconnect(_ connection: NWConnection) {\n' + immediate + cleanup.replace('self.', '') + '\n}'
    body = (here / 'Dispatch.swift').read_text()
    for key, value in pieces.items():
        assert body.count('// ' + key + '\n') == 1, key
        body = body.replace('// ' + key + '\n', value.replace('private ', '') + '\n', 1)
    files['Dispatch.swift'] = body
    files['Goodbye.swift'] = 'import Foundation\n' + block((root / 'Sources/StreamProtocol/Remote.swift').read_text(), 'public struct Goodbye:') + '\n'
    manifest = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in files.items()}
    manifest.update({'boundary:' + name: hashlib.sha256(value.encode()).hexdigest() for name, value in pieces.items()})
    # These lifecycle calls sit in a larger initializer / source observer and are not replaced by test policy.
    for marker in ['microphoneIngress.close(connection)', 'microphoneReceiver.revoke(peer: microphonePeer, reason: "disconnected")',
                   'microphoneIngress.revoke()', 'microphoneReceiver.forgetCapabilities()', 'microphoneReceiver.revoke(reason: "source changed")']:
        assert marker in coordinator, marker
    assert coordinator.index('microphoneIngress.close(connection)') < coordinator.index('self.routes[id] = nil')
    return files, manifest
