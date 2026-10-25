import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
phase = sys.argv[1]
assert phase in {'red', 'green'}
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'CCR-Vision'], text=True))
archive = Path(route['path']) / 'vision-bluetooth-profile-20261026' / phase
archive.mkdir()
paths = ['Sources/StreamProtocol/' + name + '.swift' for name in ['AudioPacket', 'StreamMessage',
    'AudioRouting', 'Switcher', 'Sentry', 'SentryControl', 'TestDestinations', 'AudioPrivacy']]
paths += ['visionOSClient/VisionAudio' + name + '.swift' for name in ['Buffer', 'Hardware', 'Player',
    'Gain', 'NativeGraph', 'State', 'Controller', 'Route']]
paths += ['iOSClient/StreamClient.swift', 'Tests/checks/vision-audio-session/run.py',
    'Tests/checks/vision-audio-session/main.swift', 'Tests/checks/vision-audio-session/NativeProfile.swift',
    'Tests/checks/vision-audio-session/run-mini.py', 'Tests/checks/vision-audio-player/main.swift',
    'Tests/checks/vision-audio-consent/main.swift', 'Tests/checks/vision-audio-consent/adapter/main.swift']
hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sorted(paths)}
(archive / 'input-before.json').write_text(json.dumps(hashes, indent=2) + '\n')
command = '''import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path.cwd()
manifest=json.loads((root/'manifest.json').read_text())
matched=all(hashlib.sha256((root/'input'/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
print('REMOTE_INPUT_HASHES_MATCH '+str(matched),flush=True)
if not matched: sys.exit(2)
result=subprocess.run(['python3','input/Tests/checks/vision-audio-session/run.py',str(root/'input'),str(root/'output'),'--skip-mutants'])
for name in ['baseline-runtime','buffer-runtime','consent-runtime','controller-runtime','native-profile-runtime']:
    path=root/'output'/(name+'.log')
    if path.exists(): print(name+'\\n'+path.read_text(),flush=True)
print('REMOTE_INPUT_UNCHANGED '+str(all(hashlib.sha256((root/'input'/p).read_bytes()).hexdigest()==h for p,h in manifest.items())),flush=True)
sys.exit(result.returncode)
'''
with tempfile.TemporaryDirectory(prefix='input-', dir=archive) as folder:
    temp = Path(folder)
    for path in paths:
        target = temp / 'input' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    (temp / 'manifest.json').write_text(json.dumps(hashes, sort_keys=True) + '\n')
    result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(temp),
        '--owner', os.environ['CODEX_THREAD_ID'], '--job', 'vision-bluetooth-profile-20261026-' + phase,
        '--', 'python3', '-c', command], capture_output=True, text=True)
    log = result.stdout + result.stderr
    (archive / 'result.log').write_text(log)
    print(log, end='')
after = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in hashes}
(archive / 'input-after.json').write_text(json.dumps(after, indent=2) + '\n')
assert hashes == after
receipts = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{') and 'cleanup_verified' in line]
assert receipts and receipts[-1]['cleanup_verified'] is True
(archive / 'mini-receipt.json').write_text(json.dumps(receipts[-1], indent=2) + '\n')
assert 'REMOTE_INPUT_HASHES_MATCH True' in log and 'REMOTE_INPUT_UNCHANGED True' in log
raise SystemExit(result.returncode)
