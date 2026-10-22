#!/usr/bin/env python3
"""Mini 한시 실행 사본에서만 전체 생산 회귀와 SDK를 검증한다."""
from concurrent.futures import ThreadPoolExecutor
import base64, hashlib, importlib.util, json, os
from pathlib import Path
import subprocess, sys, tempfile, time, re
ROOT=Path(__file__).resolve().parents[3]
if '/mini-ephemeral-source/runs/' not in str(ROOT): raise SystemExit('Mini ephemeral source only')
os.chdir(ROOT)
manifest=json.loads((ROOT/'.source-hashes.json').read_text())
def unchanged():
    return all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
assert unchanged(), 'received source hash mismatch'
print('INPUT_HASHES_MATCHED '+str(len(manifest)),flush=True)

def run(name, command, source=None, expected=0):
    start=time.monotonic()
    p=subprocess.run(command,input=source,capture_output=True)
    logs=p.stdout+p.stderr
    matched=p.returncode==expected and (expected==0 or re.search(rb'topology production checks=\d+ failures=[1-9]\d*',logs) is not None)
    record={'expectedExit':expected,'expectationMet':matched,'test':name,'exit':p.returncode,'seconds':round(time.monotonic()-start,2),
            'log':base64.b64encode(p.stdout+p.stderr).decode()}
    print('TEST_RESULT '+json.dumps(record),flush=True)
    return 0 if matched else 1

def sdk():
    return run('SillMenuBar-SDK',['swift','build','--product','SillMenuBar','--scratch-path',str(ROOT/'.build/sdk'),
        '--cache-path',str(ROOT/'.build/spm-cache'),'-Xswiftc','-module-cache-path','-Xswiftc',str(ROOT/'.build/sdk-module-cache')])

jobs=[lambda:run('topology-baseline-9396',['python3','Tests/checks/source-intent/run.py','--suite','topology','--coordinator-file','.topology-9396.swifttext'],expected=1),
      lambda:run('topology',['python3','Tests/checks/source-intent/run.py','--suite','topology']),
      lambda:run('source-intent',['python3','Tests/checks/source-intent/run.py']),
      lambda:run('publication',['python3','Tests/checks/source-intent/run.py','--suite','publication']),
      lambda:run('gesture',['python3','Tests/checks/gesture-drain-scope/run.py','--run']),
      lambda:run('monitor',['bash','Tests/checks/monitor-selection/run.sh']),
      lambda:run('owner-bootstrap',['python3','Tests/checks/owner-mac-bootstrap/run.py']),sdk]
if '--skip-sdk' in sys.argv: jobs=jobs[:-1]
with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
    results=list(pool.map(lambda job:job(), jobs))
assert unchanged(), 'Mini source changed during checks'
print('POST_INPUT_HASHES_UNCHANGED true',flush=True)
binary=ROOT/'.build/sdk/debug/SillMenuBar'
if binary.exists(): print('SDK_BINARY_SHA256 '+hashlib.sha256(binary.read_bytes()).hexdigest(),flush=True)
raise SystemExit(0 if all(code==0 for code in results) else 1)
