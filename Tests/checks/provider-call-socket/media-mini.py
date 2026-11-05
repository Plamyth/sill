"""Exercise exact production duplex I/O on socketpair; peer identity is explicitly stubbed."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
paths = ['Sources/SillHost/ProviderCallSocket.swift', 'Sources/SillHost/LocalAudioRelay.swift',
         'Tests/checks/provider-call-socket/MediaChecks.swift']
sha = lambda x: hashlib.sha256(x).hexdigest()
before = {p: sha((root / p).read_bytes()) for p in paths}
assert not subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'])
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip()
source = (root / paths[0]).read_text()
source = source.replace('    private static func write(', '    static func write(').replace('    private static func readExactly(', '    static func readExactly(')
source = source.replace('    deinit { invalidate() }', '    init(testDescriptor: Int32) { descriptor = testDescriptor; frameLimit = 32_769 }\n    deinit { invalidate() }')
relay = (root / paths[1]).read_text()
validator = relay[relay.index('enum LocalAudioRelayJSON {'):relay.index('@MainActor\nfinal class LocalAudioRelay')]
with tempfile.TemporaryDirectory(prefix='provider-media-input-') as temp:
    stage = Path(temp)
    (stage / 'Socket.swift').write_text(source)
    (stage / 'JSON.swift').write_text('import Foundation\n' + validator)
    (stage / 'Checks.swift').write_bytes((root / paths[2]).read_bytes())
    run_script = '''import subprocess\nsubprocess.run(['xcrun','swiftc','-parse-as-library','Socket.swift','JSON.swift','Checks.swift','-o','checks'],check=True)\nsubprocess.run(['./checks'],check=True)\n'''
    (stage / 'run.py').write_text(run_script)
    staged = {p.name: sha(p.read_bytes()) for p in stage.iterdir()}
    command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
               '--owner', '01a13005-ff61-7780-b0e8-6dc171de1c9d', '--job', 'provider-media-socket-20261105',
               '--', '/usr/bin/env', 'PATH=/Users/sin-wonho/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               'python3', '-B', 'run.py']
    run = subprocess.run(command, capture_output=True, text=True, timeout=240)
    assert staged == {p.name: sha(p.read_bytes()) for p in stage.iterdir()}
assert before == {p: sha((root / p).read_bytes()) for p in paths}
receipts = [json.loads(s) for s in run.stderr.splitlines() if s.startswith('{"receipt":')]
assert receipts and receipts[-1]['cleanup_verified']
result = dict(commit=commit, sourceHashes=before, stagedHashes=staged, sourceUnchanged=True,
              peerAuthenticationStubbed=True, actualCoreAccepted=False, actualAudioAccepted=False,
              stdout=run.stdout, stderr=run.stderr, exitCode=run.returncode, cleanup=receipts[-1])
output.write_text(json.dumps(result, indent=2) + '\n')
print(run.stdout[-5000:]); print(run.stderr[-5000:] if run.returncode else 'cleanup_verified=true')
raise SystemExit(run.returncode)
