#!/usr/bin/env python3
"""Independent RAM-input checks on Mini; never a source-guard task-transfer receipt."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
label = sys.argv[1]
if not re.fullmatch(r'[a-z0-9-]{1,48}', label):
    raise SystemExit('invalid receipt label')
out = HERE / 'receipts'
out.mkdir(exist_ok=True)
if (out / (label + '.json')).exists() or (out / (label + '.log')).exists():
    raise SystemExit('reconcile existing attempt; receipts are never overwritten')
sha = lambda data: hashlib.sha256(data).hexdigest()

def block(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

coordinator = (ROOT / 'Sources/SillHost/StreamCoordinator.swift').read_text()
methods = [block(coordinator, signature) for signature in [
    'private func audioRouteAuthorized(', 'private func sendAudioRouteState(',
    'private func publishAudioRoutes(', 'private func handleAudioRoute('
]]
fixture = (HERE / 'CoordinatorFixture.swift').read_text()
fixture = fixture.replace('    // PRODUCTION_COORDINATOR_METHODS', '\n\n'.join(methods))
assert 'case .changeAudioRoute, .fetchAudioRoutes:\n            handleAudioRoute(message, from: connection)' in coordinator
assert 'self?.publishAudioRoutes()' in block(coordinator, 'catalog.onPolled =')
assert 'sendAudioRouteState(audioHardwareRoutes.observe(), to: connection)' in block(coordinator, 'private func sendCatalog(')
paths = sorted((ROOT / 'Sources').rglob('*'))
paths = [p for p in paths if p.is_file()]
paths += [ROOT / 'Package.swift', HERE / 'main.swift', HERE / 'CoordinatorFixture.swift', HERE / 'remote.py', Path(__file__).resolve()]
original = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
sources = {str(p.relative_to(ROOT)): p.read_bytes() for p in paths if p.suffix in ('.swift', '.h', '.m', '.c')}
sources['Tests/checks/audio-routing/CoordinatorFixture.swift'] = fixture.encode()
hashes = {name: sha(data) for name, data in sources.items()}
payload = json.dumps({'source': {name: base64.b64encode(data).decode() for name, data in sources.items()},
                      'hashes': hashes, 'hostCompile': '--host' in sys.argv}).encode()

def containers():
    result = subprocess.run(['docker', '--context', 'cargo24-mini', 'ps', '-a', '--format', '{{.ID}} {{.Names}} {{.Status}}'],
                            capture_output=True, text=True, timeout=20)
    return {'exitCode': result.returncode, 'rows': result.stdout.splitlines()}

before = containers()
runner = (HERE / 'remote.py').read_text()
command = ['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner]
if '--wait-slot' in sys.argv:
    # A bounded semaphore wait, with identical input. Retry only a definite pre-start refusal
    # after observing release; the standard heavy runner still owns admission and execution.
    queue = r'''
import fcntl,subprocess,sys,time
from pathlib import Path
raw=sys.stdin.buffer.read();deadline=time.monotonic()+120;refusals=0
with (Path.home()/'.local/state/codex-offload/mini-heavy.lock').open('rb') as lock:
 while time.monotonic()<deadline:
  try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError: time.sleep(0.5);continue
  fcntl.flock(lock,fcntl.LOCK_UN)
  p=subprocess.run(['/Users/sin-wonho/.local/bin/codex-mini-heavy-run','--','python3','-B','-c',sys.argv[1]],input=raw,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  if p.returncode==75 and p.stdout.strip()==b'Mac mini heavy-job slot is occupied':
   refusals+=1;time.sleep(0.5);continue
  print('QUEUE_PRESTART_REFUSALS '+str(refusals),flush=True);sys.stdout.buffer.write(p.stdout);sys.stdout.flush();sys.exit(p.returncode)
print('HEAVY_SLOT_UNAVAILABLE_AFTER_120S',flush=True);sys.exit(75)
'''
    command = ['/Users/ambrion/.local/bin/mini', 'run', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', queue, runner]
process = subprocess.Popen(command, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    log, _ = process.communicate(payload, timeout=780)
except subprocess.TimeoutExpired:
    process.terminate()
    log, _ = process.communicate(timeout=30)
(out / (label + '.log')).write_bytes(log)
records = [line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
record = {'taskKey': 'ccr-cross-device-mac-audio-20261016', 'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
          'scope': 'Independent RAM-source policy/coordinator fixture and optional host compile. No source-guard task transfer acceptance; no live CoreAudio, host, sockets, or device execution.',
          'exitCode': process.returncode, 'transportReaped': process.poll() is not None,
          'inputSHA256': sha(payload), 'senderReceiverMatch': ('INPUT_SHA256 ' + sha(payload)).encode() in log,
          'originalSHA256': original, 'emittedSHA256': hashes,
          'sourceUnchanged': all(sha((ROOT / name).read_bytes()) == value for name, value in original.items()),
          'extractedCoordinatorMethodsSHA256': [sha(method.encode()) for method in methods],
          'remoteResult': json.loads(records[-1]) if records else None,
          'containersBefore': before, 'containersAfter': containers()}
(out / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
seen = set()
for line in log.decode(errors='replace').splitlines():
    if line.startswith(('Audio routing:', 'FAIL ', 'Build of target:', 'RESULT_JSON ')) or 'error:' in line or 'warning:' in line:
        if line not in seen:
            print(line)
            seen.add(line)
print(json.dumps({key: record[key] for key in ['exitCode', 'senderReceiverMatch', 'sourceUnchanged', 'transportReaped']}))
sys.exit(process.returncode if record['sourceUnchanged'] and record['senderReceiverMatch'] and records else 2)
