"""Run the existing runtime fixture from a clean selector commit with unchanged Node pins."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
node_repo = Path(sys.argv[2]).resolve()

def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args])

assert not git('status', '--porcelain'), 'commit owned files before fixture execution'
commit = git('rev-parse', 'HEAD').decode().strip()
tree = git('rev-parse', 'HEAD^{tree}').decode().strip()
sha = lambda raw: hashlib.sha256(raw).hexdigest()
paths = list((root / 'Sources').rglob('*.swift'))
paths += list(Path(__file__).parent.glob('*'))
paths += [root / 'Tests/checks/forwarding-evidence-lifecycle' / name
          for name in ['Main.swift', 'Boundaries.swift', 'child.js']]
paths += [root / 'docs/provider-call-native-v1.md', root / 'AGENTS.md',
          root / 'Tests/checks/provider-call-bridge/native-target-vectors.json']
paths = [path for path in paths if path.is_file()]
hashes = {str(p.relative_to(root)): sha(p.read_bytes()) for p in paths}
links = {str(p.relative_to(root)): os.readlink(p) for p in paths if p.is_symlink()}
node_commit = re.search(r'static let nodeCommit = "([a-f0-9]{40})"',
    (root / 'Sources/SillHost/LocalAudioRelayLaunch.swift').read_text()).group(1)
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
    (root / 'Sources/SillHost/LocalAudioRelayClosure.swift').read_text()))
assert pins
with tempfile.TemporaryDirectory(prefix='host-selector-input-') as temporary:
    stage = Path(temporary)
    for name in hashes:
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if name in links:
            assert (target.parent / links[name]).resolve().is_relative_to(stage.resolve())
            target.symlink_to(links[name])
        else:
            target.write_bytes((root / name).read_bytes())
    for name, digest in pins.items():
        raw = subprocess.check_output(['git', '-C', str(node_repo), 'show', node_commit + ':' + name])
        assert sha(raw) == digest, name
        target = stage / 'Node' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
    manifest = dict(productionCommit=commit, productionTree=tree, sourceHashes=hashes, sourceLinks=links)
    raw = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    (stage / 'manifest.json').write_bytes(raw)
    (stage / 'output').mkdir()
    command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
        '--owner', os.environ.get('CODEX_THREAD_ID', 'native-call-selector-20261105'),
        '--job', 'host-native-call-selector-fallback-20261105', '--', '/usr/bin/env',
        'PATH=/Users/sin-wonho/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        'python3', '-B', 'Tests/checks/provider-call-runtime/run.py', '--manifest', 'manifest.json',
        '--sha256', sha(raw), '--production-commit', commit, '--production-tree', tree]
    if '--handlers-only' in sys.argv:
        command.append('--handlers-only')
    run = subprocess.run(command, capture_output=True, text=True, timeout=480)
assert hashes == {name: sha((root / name).read_bytes()) for name in hashes}
assert not git('status', '--porcelain') and git('rev-parse', 'HEAD').decode().strip() == commit
record = dict(commit=commit, tree=tree, nodeCommit=node_commit, sourceHashes=hashes,
              sourceUnchanged=True, stdout=run.stdout, stderr=run.stderr, exitCode=run.returncode)
output.write_text(json.dumps(record, indent=2) + '\n')
for line in run.stdout.splitlines():
    if line.startswith('RUNTIME_RESULT='):
        result = json.loads(line.removeprefix('RUNTIME_RESULT='))
        print(json.dumps({key: result[key] for key in ['checkCount', 'passedCount', 'failures', 'exitCode']}))
if run.returncode:
    print(run.stdout[-14000:])
    print(run.stderr[-5000:])
print('RECEIPT ' + str(output))
sys.exit(run.returncode)
