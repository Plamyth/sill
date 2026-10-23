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
node_repo, archive = [Path(p).resolve(strict=True) for p in sys.argv[1:]]
commit = '099dcd8cbd846b7b54395e6a2c9e7df868fd1eea'
names = ['LocalAudioParticipants', 'LocalAudioRelay', 'AudioForwardingContract', 'AudioForwardingCoordinator',
         'AudioForwardingParticipants', 'AudioForwardingProtection', 'HostAudioForwardingRuntime']
sources = [root / 'Sources/SillHost' / (name + '.swift') for name in names]
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = sources + protocol + list(here.glob('*.*'))
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
                     (root / 'Sources/SillHost/LocalAudioRelayClosure.swift').read_text()))
node_hashes = {}
with tempfile.TemporaryDirectory(prefix='evidence-lifecycle-', dir=archive) as temporary:
    out = Path(temporary)
    node = out / 'node-source'
    node.mkdir()
    for name in ['audio-forwarding-authority.js', 'native-audio-control.js', 'audio-session.js']:
        data = subprocess.check_output(['git', '-C', str(node_repo), 'show', commit + ':server/' + name])
        digest = hashlib.sha256(data).hexdigest()
        assert digest == pins['server/' + name]
        (node / name).write_bytes(data)
        node_hashes[name] = digest
    runtime = out / 'Runtime.swift'
    runtime.write_text(sources[-1].read_text() + '''
extension HostAudioForwardingRuntime {
    var checkSessionCount: Int { sessions.count }
    var checkRecoveryBlocked: Bool { recoveryBlocked }
    func checkRefresh() async { await refresh() }
}
''')
    base = ['xcrun', 'swiftc', '-package-name', 'Sill', '-module-cache-path', str(out / 'cache')]
    subprocess.run(base + ['-emit-module', '-emit-library', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(out / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(out / 'StreamProtocol.swiftmodule')], check=True, timeout=180)
    subprocess.run(base + ['-parse-as-library', '-I', str(out), '-L', str(out), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(out), *map(str, sources[:-1]), str(runtime),
        str(here / 'Boundaries.swift'), str(here / 'Main.swift'), '-o', str(out / 'checks')], check=True, timeout=180)
    checks = out / 'cases'
    checks.mkdir()
    import shutil
    worker = subprocess.Popen([str(out / 'checks'), shutil.which('node'), str(here / 'child.js'), str(checks), str(node)],
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
print(json.dumps({'passed': True, 'sourceUnchanged': True, 'sourceHashes': before,
                  'nodeSourceCommit': commit, 'nodeSourceHashes': node_hashes,
                  'actualAudioOrDeviceActions': 0, 'scratchRemoved': not out.exists()}))
