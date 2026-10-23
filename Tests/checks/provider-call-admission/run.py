"""Actual Swift admission/signing + pinned Node stdio; no app or key store startup."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
shared = here.parent / 'forwarding-evidence-lifecycle'
node_repo, archive = [Path(p).resolve(strict=True) for p in sys.argv[1:]]
base_commit = '67603596bbebe3e2b3aaf970859935fd5bfc732f'
node_commit = '0bec7a9970b0bd4e15390012b8ade02ed54605c2'
names = ['LocalAudioParticipants', 'LocalAudioRelay', 'AudioForwardingContract',
         'AudioForwardingCoordinator', 'AudioForwardingParticipants', 'AudioForwardingProtection',
         'HostAudioForwardingRuntime', 'ProviderCallBridge']
sources = [root / 'Sources/SillHost' / (name + '.swift') for name in names]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
identity = root / 'Sources/SillHost/HostIdentity.swift'
closure = root / 'Sources/SillHost/LocalAudioRelayClosure.swift'
inputs = sources + protocol + [identity, closure] + list(here.glob('*.*')) + [
    shared / name for name in ['Boundaries.swift', 'Main.swift', 'child.js']]
sha = lambda data: hashlib.sha256(data).hexdigest()
before = {str(p.relative_to(root)): sha(p.read_bytes()) for p in inputs}
if (root / '.git').exists():
    for path in sources + protocol + [identity, closure]:
        assert path.read_bytes() == subprocess.check_output([
            'git', '-C', str(root), 'show', base_commit + ':' + str(path.relative_to(root))])
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"', closure.read_text()))
if (node_repo / '.git').exists():
    def node_source(name):
        return subprocess.check_output(['git', '-C', str(node_repo), 'show', node_commit + ':' + name])
    files = subprocess.check_output(['git', '-C', str(node_repo), 'ls-tree', '--name-only',
                                     node_commit, 'server/'], text=True).splitlines()
    files = {name for name in files if name.endswith(('.js', '.py'))}
else:
    def node_source(name):
        return (node_repo / name).read_bytes()
    files = {str(p.relative_to(node_repo)) for p in (node_repo / 'server').iterdir() if p.is_file()}
assert len(pins) == 19 and files == set(pins)
node_hashes = {name: sha(node_source(name)) for name in sorted(files)}
assert node_hashes == pins
selections = {}

def selected(path, start, end):
    text = path.read_text()
    section = text[text.index(start):text.index(end)]
    selections[str(path.relative_to(root)) + ':' + start] = {
        'sourceSha256': sha(path.read_bytes()), 'selectedSha256': sha(section.encode()),
        'firstLine': text[:text.index(start)].count('\n') + 1,
        'endMarker': end}
    return section

result = {}
with tempfile.TemporaryDirectory(prefix='provider-call-admission-', dir=archive) as temporary:
    out = Path(temporary)
    node = out / 'node-source'
    node.mkdir()
    for name in ['audio-forwarding-authority.js', 'native-audio-control.js', 'audio-session.js']:
        (node / name).write_bytes(node_source('server/' + name))
    runtime = out / 'Runtime.swift'
    runtime.write_text((root / 'Sources/SillHost/HostAudioForwardingRuntime.swift').read_text() + '''
extension HostAudioForwardingRuntime {
    var checkSessionCount: Int { sessions.count }
    var checkRecoveryBlocked: Bool { recoveryBlocked }
    func checkRefresh() async { await refresh() }
    func checkPausePolling() { polling?.cancel(); polling = nil }
}
''')
    support = out / 'Fixture.swift'
    support.write_text(selected(shared / 'Main.swift', 'import Foundation', '@main struct Checks'))
    signing = out / 'Identity.swift'
    signing.write_text('''import Foundation
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
''' + selected(identity, '    package func signRecord(', '    /// A fresh TXT record') + '}\n')
    swift = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(swift + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
    compile_sources = [path for path in sources if path.name != 'HostAudioForwardingRuntime.swift']
    compile_sources += [runtime, support, signing, shared / 'Boundaries.swift']
    common = swift + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
                     '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, compile_sources)]
    # Each probe must fail for its specific inaccessible/immutable API, not a missing dependency.
    probes = {
        'raw-scope-signing': ('func probe(_ s: ProviderCallSigner, _ c: ProviderCallChallenge, _ r: ProviderCallRequest, _ x: ProviderCallScope, _ ctx: AudioForwardingConnectionContext) throws { _ = try s.dispatchProof(c, request: r, scope: x, context: ctx) }', 'extra arguments'),
        'replace-request': ('func probe(_ p: ProviderCallPrepared, _ r: ProviderCallRequest) { p.request = r }', "'request' is a 'let' constant"),
        'replace-challenge': ('func probe(_ p: ProviderCallPrepared, _ c: ProviderCallChallenge) { p.challenge = c }', "'challenge' is a 'let' constant"),
        'fabricate-prepared': ('func probe() { _ = ProviderCallPrepared() }', "'ProviderCallPrepared' initializer is inaccessible"),
        'fabricate-approval': ('func probe() { _ = ProviderCallApproval() }', "'ProviderCallApproval' initializer is inaccessible"),
    }
    negative = []
    for name, (body, diagnostic) in probes.items():
        probe = out / 'Probe.swift'
        probe.write_text('import Foundation\nimport StreamProtocol\n@MainActor\n' + body)
        test = subprocess.run(common + ['-typecheck', str(probe)], capture_output=True, text=True, timeout=180)
        assert test.returncode != 0 and diagnostic in test.stderr, (name, test.stderr)
        negative.append(name)
    print('COMPILE_REJECTIONS=' + json.dumps(negative), flush=True)
    subprocess.run(common + [str(here / 'Main.swift'), '-o', str(out / 'checks')], check=True, timeout=180)
    cases = out / 'cases'
    cases.mkdir()
    worker = subprocess.Popen([str(out / 'checks'), shutil.which('node'), str(shared / 'child.js'),
        str(cases), str(node)], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = worker.communicate(timeout=120)
        print(output, flush=True)
        report = cases / 'report.json'
        assert report.exists(), (worker.returncode, output)
        result = json.loads(report.read_text())
        result['exitCode'] = worker.returncode
        result['fixtureProcessGroup'] = worker.pid
        result['fixtureChildren'] = []
        for info in sorted(cases.rglob('child-*.json')):
            child = json.loads(info.read_text())
            try:
                os.kill(child['pid'], 0)
                child['absentAfterChecks'] = False
            except ProcessLookupError:
                child['absentAfterChecks'] = True
            child['fixture'] = str(info.relative_to(cases))
            result['fixtureChildren'].append(child)
        assert result['fixtureChildren'] and all(child['absentAfterChecks'] for child in result['fixtureChildren'])
        # Retain only fixture logs, never credential/key files or a real journal.
        result['fixtureLogs'] = {str(p.relative_to(cases)): p.read_text() for p in cases.rglob('*.jsonl')}
        assert worker.returncode == (0 if not result['failures'] else 1)
    finally:
        try:
            os.killpg(worker.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
assert before == {str(p.relative_to(root)): sha(p.read_bytes()) for p in inputs}
assert node_hashes == {name: sha(node_source(name)) for name in sorted(files)}
result.update(sourceCommit=base_commit, sourceTree='0bf2a6f9c116a8894728bb8a57d8066ecabba590',
    sourceUnchanged=True, sourceHashes=before, selectedSource=selections, nodeSourceCommit=node_commit,
    nodeSourceHashes=node_hashes, compileRejections=negative, scratchRemoved=not out.exists(),
    actualAppDeviceHALKeychainProviderActions=0, snapshotOnly=not (root / '.git').exists())
print('ADMISSION_RESULT=' + json.dumps(result, ensure_ascii=False), flush=True)
sys.exit(result['exitCode'])
