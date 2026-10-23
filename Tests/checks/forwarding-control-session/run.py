import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

server = root / 'Sources/SillHost/StreamServer.swift'
relay = root / 'Sources/SillHost/LocalAudioRelay.swift'
role = root / 'Sources/SillHost/StreamPeerRole.swift'
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = [server, relay, role, here / 'Main.swift', Path(__file__)] + protocol
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before = hashes()
source = (here / 'Main.swift').read_text()
for marker in ['final class ForwardingExchange:', 'private func receiveForwarding(', 'func sendForwardingState(']:
    source = source.replace('// ' + marker, block(server.read_text(), marker).removeprefix('private '))
source = source.replace('// JSON', block(relay.read_text(), 'enum LocalAudioRelayJSON {'))
with tempfile.TemporaryDirectory(prefix='forwarding-control-') as temporary:
    out = Path(temporary)
    fixture = out / 'Main.swift'
    fixture.write_text(source)
    base = ['swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(base + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True)
    subprocess.run(base + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), str(role), str(fixture), '-o', str(out / 'check')], check=True)
    subprocess.run([str(out / 'check')], check=True, timeout=30)
assert hashes() == before
print(json.dumps({'passed': True, 'sourceUnchanged': True, 'sourceHashes': before,
                  'realDeviceOrAudioActions': 0, 'scratchRemoved': not out.exists()}))
