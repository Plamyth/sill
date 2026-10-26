import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('transport', here.parent / 'peer-video-transport/run.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
host = (root / 'Sources/SillHost/StreamServer.swift').read_text()
methods = ['publishScreenDemand(', 'screenDemandSelection(', 'screenDemandTrustChanged(',
           'currentVideoAdmission(', 'catalogMatches(', 'enablePeerVideo(', 'resetPeerVideo(',
           'preparePeerVideo(', 'commitPeerVideo(', 'sendPeerCatalog(', 'prepareVideo(', 'commitVideo(']
fixture = (here.parent / 'peer-video-transport/Fixture.swift').read_text().split('final class StreamServer {')[0]
types = '\n'.join(transport.block(host, marker) for marker in [
    'private enum VideoLane:', 'private final class PeerVideo {', 'private final class Client {'])
fields = '''
let queue = DispatchQueue(label: "inert.screen-demand")
var clients: [ObjectIdentifier: Client] = [:]
var videoAdmission = VideoEpochAdmission.stopped
var legacyScreenDemandIdentity: RemoteScreenDemandObservation.Source?
let screenDemandGeneration = UUID()
var screenDemandRevision: UInt64 = 0
var screenDemandTrust: TrustBox?
var onScreenDemand: ((RemoteScreenDemandObservation) -> Void)?
var lastParameterSets: Data?
final class ForwardingExchange {}
final class ProviderExchange {}
func updateTicking() {}
func send(_ data: Data, to client: Client) {}
func flush() { queue.sync {} }
func add(_ c: NWConnection) {
    queue.sync {
        let client = Client(c)
        client.route.encrypted = true
        client.route.fingerprint = Data([1])
        clients[ObjectIdentifier(c)] = client
    }
}
'''
helpers = '''
final class TrustBox {
    var trusted = true
    var snapshot: TrustBox { self }
    func isPaired(_ fingerprint: Data) -> Bool { trusted && fingerprint == Data([1]) }
}
enum RemoteScreenDemandIdentity {
    static var current = true
    static func isCurrent(_ source: RemoteScreenDemandObservation.Source) -> Bool { current }
}
'''
paths = ['Sources/SillHost/RemoteScreenDemand.swift', 'Sources/SillHost/StreamPeerRole.swift']
program = 'import StreamProtocol\n' + '\n'.join((root / path).read_text() for path in paths)
bridge = (root / 'Sources/SillHost/ProviderCallBridge.swift').read_text()
program += '\n' + bridge[bridge.index('private struct ProviderKey:'):bridge.index('func providerSameSnapshot(')]
program += '\nenum ProviderCallFailure: Error { case invalidFields, invalidIdentity }\n'
program += '\n' + transport.block(host, 'final class SourcePublicationAdmission:')
program += '\n' + fixture + '\n' + helpers
program += '\nfinal class StreamServer {\n' + types + fields
program += '\n'.join(transport.block(host, 'func ' + marker) for marker in methods) + '\n}\n'
program += (here / 'Checks.swift').read_text()
program = re.sub(r'\bprivate ', '', program)
with tempfile.TemporaryDirectory(prefix='screen-demand-server-') as temporary:
    scratch = Path(temporary)
    protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-emit-library',
                    '-emit-module', '-module-name', 'StreamProtocol', *map(str, protocol),
                    '-o', str(scratch / 'libStreamProtocol.dylib')], cwd=scratch, check=True)
    (scratch / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-I', str(scratch), '-L', str(scratch),
                    '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(scratch),
                    str(scratch / 'main.swift'), '-o', str(scratch / 'checks')], check=True)
    subprocess.run([str(scratch / 'checks')], check=True, timeout=20)
print(json.dumps({'sourceSha256': hashlib.sha256(host.encode()).hexdigest(),
                  'programSha256': hashlib.sha256(program.encode()).hexdigest(),
                  'scope': 'actual production methods; inert network and OS identity fixtures; no device proof',
                  'scratchRemoved': not scratch.exists()}))
