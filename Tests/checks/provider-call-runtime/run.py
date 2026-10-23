"""Exact production Runtime, real Node private stdio, inert Core and handler API fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
shared = here.parent / 'forwarding-evidence-lifecycle'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--manifest', required=True, type=Path)
parser.add_argument('--sha256', required=True)
parser.add_argument('--production-commit', required=True)
parser.add_argument('--production-tree', required=True)
args = parser.parse_args()
sha = lambda data: hashlib.sha256(data).hexdigest()
raw = args.manifest.read_bytes()
assert sha(raw) == args.sha256, 'manifest SHA mismatch'
manifest = json.loads(raw)
assert re.fullmatch('[a-f0-9]{40}', args.production_commit)
assert re.fullmatch('[a-f0-9]{40}', args.production_tree)
assert manifest['productionCommit'] == args.production_commit
assert manifest['productionTree'] == args.production_tree
required = {str(path.relative_to(root)) for path in (root / 'Sources').rglob('*.swift')}
required |= {str(path.relative_to(root)) for path in here.iterdir() if path.is_file()}
required |= {'Tests/checks/forwarding-evidence-lifecycle/' + name for name in ['Main.swift', 'Boundaries.swift', 'child.js']}
required |= {'docs/provider-call-native-v1.md', 'AGENTS.md'}
assert set(manifest['sourceHashes']) == required, 'source/test input set mismatch'
before = {name: sha((root / name).read_bytes()) for name in manifest['sourceHashes']}
assert before == manifest['sourceHashes'], 'source/test input mismatch'
for name, link in manifest.get('sourceLinks', {}).items():
    assert (root / name).is_symlink() and os.readlink(root / name) == link, 'source link mismatch'
node = root / 'Node/server'
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
    (root / 'Sources/SillHost/LocalAudioRelayClosure.swift').read_text()))
assert len(pins) == 19
assert {str(p.relative_to(node.parent)) for p in node.iterdir()} == set(pins)
assert {name: sha((node.parent / name).read_bytes()) for name in pins} == pins
selections = {}

def selected(name, start, end):
    path = root / name
    text = path.read_text()
    section = text[text.index(start):text.index(end)]
    selections[name + ':' + start] = dict(sourceSha256=sha(path.read_bytes()),
        selectedSha256=sha(section.encode()), firstLine=text[:text.index(start)].count('\n') + 1, endMarker=end)
    return section

names = ['LocalAudioParticipants', 'LocalAudioRelay', 'AudioForwardingContract',
    'AudioForwardingCoordinator', 'AudioForwardingParticipants', 'AudioForwardingProtection',
    'ProviderCallBridge', 'ProviderCallRuntime', 'ProviderCallSocket', 'ProviderPeerAnchor',
    'ProviderCallRecovery', 'LocalAudioRelayClosure', 'LocalAudioRelayLaunch', 'LocalAudioRelayMachO']
result = {}
with tempfile.TemporaryDirectory(prefix='runtime-check-', dir=root / 'output') as temporary:
    out = Path(temporary)
    runtime = out / 'Forwarding.swift'
    runtime.write_text((root / 'Sources/SillHost/HostAudioForwardingRuntime.swift').read_text() + '''
extension HostAudioForwardingRuntime {
    func checkPausePolling() { polling?.cancel(); polling = nil }
}
''')
    support = out / 'Fixture.swift'
    support.write_text(selected('Tests/checks/forwarding-evidence-lifecycle/Main.swift', 'import Foundation', '@main struct Checks'))
    identity = out / 'Identity.swift'
    identity.write_text('''import Foundation
import Security
import CryptoKit
import StreamProtocol
final class HostIdentity {
    let remote: RemoteIdentity
    var fingerprint: Data { remote.fingerprint }
    init() throws {
        let bytes = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).x963Representation
        guard let key = RemoteKey.importPrivate(bytes), let remote = RemoteIdentity(privateKey: key) else {
            throw ProviderCallFailure.invalidIdentity
        }
        self.remote = remote
    }
''' + selected('Sources/SillHost/HostIdentity.swift', '    package func signRecord(', '    /// A fresh TXT record') + '}\n')
    handlers = out / 'Handlers.swift'
    handlers.write_text((here / 'Handlers.swift').read_text().replace('// PRODUCTION_EXCHANGES',
        selected('Sources/SillHost/StreamServer.swift', '    final class ForwardingExchange:', '    private var viewerCount:'))
        .replace('// PRODUCTION_HANDLERS', selected('Sources/SillHost/StreamServer.swift',
            '    private func receiveForwarding(', '    private func replayCatalog('))
        .replace('// PRODUCTION_COORDINATOR', selected('Sources/SillHost/StreamCoordinator.swift',
            '    private func handleProvider(', '    private func handleForwarding(')))
    protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
    swift = ['xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
    sources = [root / 'Sources/SillHost' / (name + '.swift') for name in names]
    binary = out / 'checks'
    subprocess.run(swift + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources), str(runtime), str(support), str(identity),
        str(shared / 'Boundaries.swift'), str(handlers), str(here / 'SocketChecks.swift'),
        str(here / 'Main.swift'), '-o', str(binary)], check=True, timeout=180)
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(binary)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(binary)], capture_output=True, text=True, check=True)
    cases = out / 'cases'; cases.mkdir()
    worker = subprocess.Popen([str(binary), shutil.which('node'), str(shared / 'child.js'), str(cases), str(node)],
        start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = worker.communicate(timeout=150)
        print(output, flush=True)
        report = cases / 'report.json'
        if not report.exists():
            raise RuntimeError('Swift exited without report: ' + str(worker.returncode))
        result = json.loads(report.read_text())
        result['exitCode'] = worker.returncode
        result['fixtureProcessGroup'] = worker.pid
        children = []
        for info in sorted(cases.rglob('child-*.json')):
            child = json.loads(info.read_text())
            for field in ['pid', 'workerPid']:
                try: os.kill(child[field], 0); child[field + 'Absent'] = False
                except ProcessLookupError: child[field + 'Absent'] = True
            assert child['port'] not in [17648, 17649]
            with socket.socket() as connection:
                connection.settimeout(0.25)
                child['portClosed'] = connection.connect_ex(('127.0.0.1', child['port'])) != 0
            child['fixture'] = str(info.relative_to(cases)); children.append(child)
        result['fixtureChildren'] = children
        result['fixtureLogs'] = {str(p.relative_to(cases)): p.read_text() for p in cases.rglob('*.jsonl')}
        assert children and all(c['pidAbsent'] and c['workerPidAbsent'] and c['portClosed'] for c in children), 'fixture child/listener leaked'
        assert worker.returncode == (1 if result['failures'] else 0)
    finally:
        try: os.killpg(worker.pid, signal.SIGTERM)
        except ProcessLookupError: pass
assert before == {name: sha((root / name).read_bytes()) for name in before}
result.update(sourceHashes=before, selectedSource=selections, sourceUnchanged=True,
    productionCommit=manifest['productionCommit'], productionTree=manifest['productionTree'],
    sourceManifestSha256=args.sha256, nodeCommit='0bec7a9970b0bd4e15390012b8ade02ed54605c2',
    nodeHashes=pins, scratchRemoved=not out.exists(), fullGitSourceGuardAccepted=False,
    sourceAdmission='exact SHA snapshot; Mini has no Git checkout',
    sourceLinks=manifest.get('sourceLinks', {}),
    nodeVersion=subprocess.check_output(['node', '--version'], text=True).strip(),
    signedFixtureInformation=signature.stderr,
    signedInertFixture=True, actualAppsPorts17648_17649_HALDeviceKeychainProviderEffects=0,
    coordinator='exact selected handleProvider and StreamServer handlers executed with inert connection/pairing state')
print('RUNTIME_RESULT=' + json.dumps(result, ensure_ascii=False), flush=True)
raise SystemExit(result['exitCode'])
