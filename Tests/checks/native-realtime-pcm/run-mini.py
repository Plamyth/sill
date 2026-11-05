import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'CCR-Vision'
]))
archive = Path(route['path']) / 'host-native-pcm-20261105'
stage = archive / 'validation-input'
stage.mkdir(exist_ok=True)
names = ['Sources/SillHost/NativeRealtimePCM.swift', 'Tests/checks/native-realtime-pcm/main.swift']
sha = lambda value: hashlib.sha256(value).hexdigest()
original = {name: (root / name).read_bytes() for name in names}
hashes = {name: sha(value) for name, value in original.items()}
for name, value in original.items():
    (stage / Path(name).name).write_bytes(value)
    assert (stage / Path(name).name).read_bytes() == value

runner = r'''
import hashlib,json,pathlib,subprocess,sys,tempfile
root=pathlib.Path.cwd()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
before={p.name:sha(p) for p in root.glob('*.swift')}
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
commands=[]
with tempfile.TemporaryDirectory(prefix='native-pcm-fixture-') as output:
 out=pathlib.Path(output)
 common=['xcrun','swiftc','-swift-version','5','-sdk',sdk,'-target','arm64-apple-macosx14.0','-module-cache-path',str(out/'cache')]
 jobs=[common+['-warnings-as-errors','-typecheck','NativeRealtimePCM.swift'],
       common+['NativeRealtimePCM.swift','main.swift','-o',str(out/'fixture')],
       [str(out/'fixture')]]
 code=0
 for command in jobs:
  result=subprocess.run(command,capture_output=True,text=True,timeout=120)
  commands.append(result.returncode)
  print(result.stdout, end='',flush=True)
  print(result.stderr, end='',file=sys.stderr,flush=True)
  if result.returncode:
   code=result.returncode
   break
 after={p.name:sha(p) for p in root.glob('*.swift')}
 assert before==after
print('NATIVE_PCM_SDK '+json.dumps({'sdk':sdk,'commands':commands,'before':before,'after':after,'temporaryBuildRemoved':not out.exists(),'actualAudioIO':0,'hostCalls':0}),flush=True)
sys.exit(code)
'''
job = 'native-pcm-input-converter'
command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(stage),
           '--owner', os.environ.get('CODEX_THREAD_ID', 'host-native-pcm-20261105'), '--job', job,
           '--', 'python3', '-B', '-c', runner]
result = subprocess.run(command, capture_output=True, text=True)
assert all((root / name).read_bytes() == value for name, value in original.items())
run_id = len(list(archive.glob('validation-*.json'))) + 1
log = archive / f'validation-{run_id:02d}.log'
log.write_text(result.stdout + result.stderr)
records = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{"receipt":')]
remote = records[-1] if records else None
record = {'exitCode': result.returncode, 'sourceHashesBefore': hashes,
          'sourceHashesAfter': {name: sha((root / name).read_bytes()) for name in names},
          'miniReceipt': remote, 'log': str(log), 'actualAudioIO': 0, 'hostCalls': 0,
          'deviceCalls': 0, 'rootLedgerWrites': 0, 'audioPayloadSaved': False}
(archive / f'validation-{run_id:02d}.json').write_text(json.dumps(record, indent=2) + '\n')
print(result.stdout, end='')
print(result.stderr, end='', file=sys.stderr)
print(json.dumps({'record': str(archive / f'validation-{run_id:02d}.json'), 'exitCode': result.returncode}))
if not remote or not remote.get('cleanup_verified'):
    raise SystemExit(2)
raise SystemExit(result.returncode)
