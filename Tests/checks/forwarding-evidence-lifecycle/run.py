import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
node_repo, archive = [Path(p).resolve(strict=True) for p in sys.argv[1:3]]
flags = sys.argv[3:]
assert flags in [[], ['--observe-only'], ['--http-first']]
commit = '4916c2b64ec9e0ce6f34c913ef0f1d2d2f3b6b57'
names = ['LocalAudioParticipants', 'LocalAudioRelay', 'AudioForwardingContract', 'AudioForwardingCoordinator',
         'AudioForwardingParticipants', 'AudioForwardingProtection', 'HostAudioForwardingRuntime']
sources = [root / 'Sources/SillHost' / (name + '.swift') for name in names]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
closure = root / 'Sources/SillHost/LocalAudioRelayClosure.swift'
bridge = root / 'Sources/SillHost/ProviderCallBridge.swift'
provider_runtime = root / 'Sources/SillHost/ProviderCallRuntime.swift'
inputs = sources + protocol + list(here.glob('*.*')) + [closure, bridge, provider_runtime]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
selections = {}


def selected(path, start, end):
    text = path.read_text()
    assert text.count(start) == 1 and text.count(end) == 1, (path.name, start, end)
    first, last = text.index(start), text.index(end)
    assert first < last
    section = text[first:last]
    selections[str(path.relative_to(root)) + ':' + start] = dict(
        sourceSha256=before[str(path.relative_to(root))],
        selectedSha256=hashlib.sha256(section.encode()).hexdigest(),
        firstLine=text[:first].count('\n') + 1, endMarker=end)
    return section


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
assert len(pins) == 24 and node_files == set(pins)
node_hashes = {name: hashlib.sha256(node_source(name)).hexdigest() for name in sorted(node_files)}
assert node_hashes == pins
with tempfile.TemporaryDirectory(prefix='evidence-lifecycle-', dir=archive) as temporary:
    out = Path(temporary)
    node = out / 'node-source'
    node.mkdir()
    for name in sorted(pins):
        data = node_source(name)
        assert hashlib.sha256(data).hexdigest() == pins[name]
        (node / Path(name).name).write_bytes(data)
    runtime = out / 'Runtime.swift'
    runtime.write_text(sources[-1].read_text() + '''
extension HostAudioForwardingRuntime {
    var checkSessionCount: Int { sessions.count }
    var checkRecoveryBlocked: Bool { recoveryBlocked }
    func checkRefresh() async { await refresh() }
}
''')
    scope = out / 'ProviderScope.swift'
    scope.write_text(selected(bridge, 'import Foundation', 'struct ProviderCallSignedEnvelope:') +
        selected(bridge, 'struct ProviderCallChallenge:', 'private struct ProviderIdentityBody:') +
        selected(provider_runtime, '@MainActor\nstruct ProviderCallSession {', '@MainActor\nfinal class ProviderCallRuntime {'))
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
        exit_code = worker.returncode
        children = []
        for info in checks.rglob('child-*.json'):
            child = json.loads(info.read_text())
            for field in ['pid', 'workerPid']:
                try:
                    os.kill(child[field], 0)
                    child[field + 'Absent'] = False
                except ProcessLookupError:
                    child[field + 'Absent'] = True
            assert child['port'] not in [17648, 17649]
            with socket.socket() as connection:
                connection.settimeout(0.25)
                child['portClosed'] = connection.connect_ex(('127.0.0.1', child['port'])) != 0
            children.append(child)
        assert children and all(c['pidAbsent'] and c['workerPidAbsent'] and c['portClosed'] for c in children), 'fixture child/listener leaked'
    finally:
        try:
            os.killpg(worker.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
assert node_hashes == {name: hashlib.sha256(node_source(name)).hexdigest() for name in sorted(node_files)}
print(json.dumps({'passed': exit_code == 0, 'exitCode': exit_code,
                  'sourceUnchanged': True, 'sourceHashes': before, 'selectedSource': selections,
                  'nodeSourceCommit': commit, 'nodeSourceHashes': node_hashes,
                  'fixtureChildren': children,
                  'actualAudioOrDeviceActions': 0, 'scratchRemoved': not out.exists()}))
sys.exit(exit_code)
