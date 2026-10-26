import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
node_repo, archive = [Path(p).resolve(strict=True) for p in sys.argv[1:3]]
flags = sys.argv[3:]
assert flags in [[], ['--observe-only']]
commit = '0bec7a9970b0bd4e15390012b8ade02ed54605c2'
names = ['LocalAudioParticipants', 'LocalAudioRelay', 'AudioForwardingContract', 'AudioForwardingCoordinator',
         'AudioForwardingParticipants', 'AudioForwardingProtection', 'HostAudioForwardingRuntime']
sources = [root / 'Sources/SillHost' / (name + '.swift') for name in names]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
closure = root / 'Sources/SillHost/LocalAudioRelayClosure.swift'
bridge = root / 'Sources/SillHost/ProviderCallBridge.swift'
inputs = sources + protocol + list(here.glob('*.*')) + [closure, bridge]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
                     closure.read_text()))
if (node_repo / '.git').exists():
    def node_source(name):
        return subprocess.check_output(['git', '-C', str(node_repo), 'show', commit + ':' + name])
    node_files = subprocess.check_output(['git', '-C', str(node_repo), 'ls-tree', '--name-only',
                                        commit, 'server/'], text=True).splitlines()
    node_files = {name for name in node_files if name.endswith(('.js', '.py'))}
else:
    def node_source(name):
        return (node_repo / name).read_bytes()
    node_files = {str(p.relative_to(node_repo)) for p in (node_repo / 'server').iterdir() if p.is_file()}
assert len(pins) == 19 and node_files == set(pins)
node_hashes = {name: hashlib.sha256(node_source(name)).hexdigest() for name in sorted(node_files)}
assert node_hashes == pins
with tempfile.TemporaryDirectory(prefix='evidence-lifecycle-', dir=archive) as temporary:
    out = Path(temporary)
    node = out / 'node-source'
    node.mkdir()
    for name in ['audio-forwarding-authority.js', 'native-audio-control.js', 'audio-session.js']:
        data = node_source('server/' + name)
        assert hashlib.sha256(data).hexdigest() == pins['server/' + name]
        (node / name).write_bytes(data)
    runtime = out / 'Runtime.swift'
    runtime.write_text(sources[-1].read_text() + '''
extension HostAudioForwardingRuntime {
    var checkSessionCount: Int { sessions.count }
    var checkRecoveryBlocked: Bool { recoveryBlocked }
    func checkRefresh() async { await refresh() }
}
''')
    bridge_source = bridge.read_text()
    scope = out / 'ProviderScope.swift'
    scope.write_text(bridge_source[:bridge_source.index('struct ProviderCallSignedEnvelope:')] +
        bridge_source[bridge_source.index('struct ProviderCallChallenge:'):bridge_source.index('private struct ProviderIdentityBody:')])
    base = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    if 'privacy: HostAudioPrivacy, sentry: HostSentry' in sources[-1].read_text():
        base += ['-D', 'LEGACY_SENTRY_RUNTIME']
    subprocess.run(base + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
    subprocess.run(base + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources[:-1]), str(runtime),
        str(scope), str(here / 'Boundaries.swift'), str(here / 'Main.swift'), '-o', str(out / 'checks')], check=True, timeout=180)
    checks = out / 'cases'
    checks.mkdir()
    import shutil
    worker = subprocess.Popen([str(out / 'checks'), shutil.which('node'), str(here / 'child.js'), str(checks), str(node), *flags],
                              start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = worker.communicate(timeout=45)
        print(output)
        if worker.returncode != 0:
            for log in checks.rglob('*.jsonl'):
                print(str(log.relative_to(checks)), log.read_text())
        assert worker.returncode == 0, worker.returncode
    finally:
        try:
            os.killpg(worker.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
assert node_hashes == {name: hashlib.sha256(node_source(name)).hexdigest() for name in sorted(node_files)}
print(json.dumps({'passed': True, 'sourceUnchanged': True, 'sourceHashes': before,
                  'nodeSourceCommit': commit, 'nodeSourceHashes': node_hashes,
                  'actualAudioOrDeviceActions': 0, 'scratchRemoved': not out.exists()}))
