#!/usr/bin/env python3
"""Parent-invoked injected HOST checks. Never instantiates a native audio backend."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True, help='new parent-approved scratch/RAM directory')
parser.add_argument('--timeout', type=int, default=180, help='explicit bounded build/test budget in seconds')
args = parser.parse_args()
if args.timeout <= 0:
    parser.error('timeout must be positive')
output = args.output.resolve()
subprocess.run([sys.executable, '-B', str(HERE / 'emit.py'), '--output', str(output)], check=True)
manifest = json.loads((output / 'manifest.json').read_text())

def unchanged():
    return all(hashlib.sha256((output / name).read_bytes()).hexdigest() == sha
               for name, sha in manifest['emittedSHA256'].items())

if not unchanged():
    raise SystemExit('emitted input changed before execution')
command = ['swift', 'run', '--package-path', str(output), 'HostPrivacyChecks']
try:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=args.timeout)
    log, code = result.stdout, result.returncode
except subprocess.TimeoutExpired as error:
    log, code = error.stdout or b'', 124
(output / 'checks.log').write_bytes(log)
record = {'command': command, 'exitCode': code, 'sourceUnchanged': unchanged(),
          'scope': 'Injected HAL/owner and extracted coordinator boundary checks only; no native hardware or app.',
          'passedAssertions': sum(line.startswith(b'PASS ') for line in log.splitlines()),
          'completed': b'Host audio privacy: all injected checks passed; no native hardware calls' in log}
(output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
sys.stdout.buffer.write(log)
print(json.dumps(record), flush=True)
raise SystemExit(0 if code == 0 and record['completed'] and record['sourceUnchanged'] else code or 2)
