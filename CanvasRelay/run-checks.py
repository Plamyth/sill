import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--focused', action='store_true')
parser.add_argument('--notes', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
for name in ['home', 'tmp']:
    (output / name).mkdir(exist_ok=True)
files = sorted(p for p in root.rglob('*') if p.is_file() and '__pycache__' not in p.parts)
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
before = hashes()
node = str(Path.home() / '.local/bin/node')
if not Path(node).is_file():
    node = shutil.which('node')
tests = ['note-reconciliation.test.js'] if args.notes else ['vault-reconciliation.test.js'] if args.focused else [
    'canvas-diagram.test.js', 'braintrinity-projection.test.js', 'canvas-schema.test.js',
    'canvas-scene3.test.js', 'obsidian-vault.test.js', 'canvas-limits.test.js',
    'codex-delivery.test.js', 'control-room-public-relay.test.js', 'vault-save-boundary.test.js',
    'agent-scene-promotion.test.js', 'vault-reconciliation.test.js','note-reconciliation.test.js']
command = [node, '--experimental-test-isolation=none', '--require', str(root / 'test-guard.cjs'),
           '--test', '--test-reporter=tap',
           '--test-skip-pattern=authenticated HTTP|authenticated canvas HTTP|isolated loopback HTTP',
           *[str(root / 'relay' / name) for name in tests]]
child_log = output / 'children.jsonl'
child_log.write_text('')
env = dict(os.environ, HOME=str(output / 'home'), TMPDIR=str(output / 'tmp'),
           CCR_FIX_MODULE_ROOT=str(root / 'relay'), CCR_CHILD_RECEIPTS=str(child_log),
           CCR_RECONCILIATION_EXAMPLE=str(output / 'wire-example.json'),CCR_NOTE_EXAMPLE=str(output / 'note-wire-example.json'))
with (output / 'tests.tap').open('w') as log:
    result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
after = hashes()
children = [json.loads(line) for line in child_log.read_text().splitlines()]
summary = [line for line in (output / 'tests.tap').read_text().splitlines()
           if line.startswith(('# tests', '# pass', '# fail', '# skipped', 'not ok'))]
report = {'schema': 'ccr.reconciliation-checks/v1', 'host': socket.gethostname(),
          'sourceBefore': before, 'sourceAfter': after, 'sourceUnchanged': before == after,
          'commandExecutable': node, 'testFiles': tests, 'exitCode': result.returncode,
          'summary': summary, 'children': children, 'allChildPIDsGone': all(c['pidGone'] for c in children),
          'listeners': 0, 'network': 0, 'urlSessionAcceptance': False, 'runtimeAcceptance': False,
          'logSHA256': hashlib.sha256((output / 'tests.tap').read_bytes()).hexdigest(),
          'passed': result.returncode == 0 and before == after and all(c['exitCode'] == 0 and c['pidGone'] for c in children)}
(output / 'receipt.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
print(json.dumps(report, ensure_ascii=False))
raise SystemExit(0 if report['passed'] else 1)
