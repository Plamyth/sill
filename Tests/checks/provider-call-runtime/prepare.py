"""Create an exact Git source/test snapshot and execute it with Mini cleanup receipts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--production-repo', required=True, type=Path)
parser.add_argument('--commit', required=True)
parser.add_argument('--node-source', required=True, type=Path)
parser.add_argument('--owner', required=True)
parser.add_argument('--attempt', required=True, type=int)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
def git(*values):
    return subprocess.check_output(['git', '-C', str(args.production_repo), *values])
commit = git('rev-parse', args.commit).decode().strip()
assert commit == args.commit, 'use full exact commit'
tree = git('rev-parse', commit + '^{tree}').decode().strip()
routed = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'CCR-Vision']))
archive = Path(routed['path']) / 'provider-call-runtime-20261024'; archive.mkdir(exist_ok=True)
stage = archive / 'input'; stage.mkdir(exist_ok=True)
sha = lambda data: hashlib.sha256(data).hexdigest()
entries = [entry.split('\t') for entry in git('ls-tree', '-r', commit, 'Sources',
    'docs/provider-call-native-v1.md', 'AGENTS.md').decode().splitlines()]
files = {name: metadata.split()[0] for metadata, name in entries if name.endswith(('.swift', '.md'))}
links = {}
for name, mode in files.items():
    raw = git('show', commit + ':' + name)
    target = stage / name; target.parent.mkdir(parents=True, exist_ok=True)
    if mode == '120000':
        link = raw.decode()
        assert (target.parent / link).resolve().is_relative_to(stage.resolve()), 'external source link'
        if target.exists() or target.is_symlink(): target.unlink()
        os.symlink(link, target); links[name] = link
    else:
        assert mode in ['100644', '100755']
        if target.is_symlink(): target.unlink()
        target.write_bytes(raw)
hashes = {name: sha((stage / name).read_bytes()) for name in files}
tests = list((root / 'Tests/checks/provider-call-runtime').glob('*'))
tests += [root / 'Tests/checks/forwarding-evidence-lifecycle' / name for name in ['Main.swift', 'Boundaries.swift', 'child.js']]
for path in tests:
    if not path.is_file(): continue
    name = str(path.relative_to(root))
    target = stage / name; target.parent.mkdir(parents=True, exist_ok=True)
    raw = path.read_bytes(); target.write_bytes(raw); hashes[name] = sha(raw)
pins = dict(re.findall(r'"(server/[^\"]+)": "([a-f0-9]{64})"',
    (stage / 'Sources/SillHost/LocalAudioRelayClosure.swift').read_text()))
assert len(pins) == 19
for name, digest in pins.items():
    raw = (args.node_source / name).read_bytes(); assert sha(raw) == digest
    target = stage / 'Node' / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
assert hashes == {name: sha((stage / name).read_bytes()) for name in hashes}
manifest = dict(productionCommit=commit, productionTree=tree, sourceHashes=hashes, sourceLinks=links)
raw = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
(stage / 'manifest.json').write_bytes(raw)
(archive / f'manifest-{args.attempt:02}.json').write_bytes(raw)
(stage / 'output').mkdir(exist_ok=True)
prefix = archive / f'mini-run-{args.attempt:02}'
command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
    '--owner', args.owner, '--job', 'provider-call-runtime-20261024', '--', '/usr/bin/env',
    'PATH=/Users/sin-wonho/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    'python3', 'Tests/checks/provider-call-runtime/run.py', '--manifest', 'manifest.json', '--sha256', sha(raw),
    '--production-commit', commit, '--production-tree', tree]
with prefix.with_suffix('.stdout.log').open('w') as out, prefix.with_suffix('.stderr.log').open('w') as err:
    run = subprocess.run(command, stdout=out, stderr=err)
for line in prefix.with_suffix('.stdout.log').read_text().splitlines():
    if line.startswith('RUNTIME_RESULT='):
        result = json.loads(line.removeprefix('RUNTIME_RESULT='))
        (archive / f'result-{args.attempt:02}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({name: result[name] for name in ['productionCommit', 'productionTree', 'checkCount', 'passedCount', 'failures', 'exitCode']}, ensure_ascii=False))
assert hashes == {name: sha((stage / name).read_bytes()) for name in hashes}, 'snapshot changed during run'
for line in prefix.with_suffix('.stderr.log').read_text().splitlines():
    if line.startswith('{"receipt":'):
        receipt = json.loads(line); assert receipt['cleanup_verified']
        (archive / f'mini-receipt-{args.attempt:02}.json').write_text(json.dumps(receipt, indent=2) + '\n')
print('exitCode', run.returncode)
if run.returncode:
    print(prefix.with_suffix('.stderr.log').read_text()[-12000:])
    print(prefix.with_suffix('.stdout.log').read_text().split('RUNTIME_RESULT=')[0][-12000:])
raise SystemExit(run.returncode)
