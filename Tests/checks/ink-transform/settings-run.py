#!/usr/bin/env python3
"""Mini에서 제품 모델과 명령 회귀를 실행하고 한시적 소스 삭제를 확인한다."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
output = Path(sys.argv[1]).resolve()
if not output.is_relative_to(Path(route['path']).resolve()):
    raise SystemExit('storage-route 외장 검사 경로가 필요합니다.')
output.mkdir(parents=True, exist_ok=True)
model = 'iOSClient/CanvasBridge/CanvasModel.swift'
suites = ['ink-transform/PenSettingsChecks.swift', 'ipad-canvas-revisions/main.swift',
          'canvas-hierarchy/main.swift', 'node-comments/main.swift']
inputs = [model] + ['Tests/checks/' + suite for suite in suites]

def hashes():
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs}

before = hashes()
program = '''import hashlib,json,pathlib,subprocess
root=pathlib.Path.cwd()
inputs=INPUTS
def hashes(): return {name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in inputs}
before=hashes()
out=root/'.build/ink-style-model'
out.mkdir(parents=True,exist_ok=True)
for index,suite in enumerate(inputs[1:]):
 binary=out/('check-'+str(index))
 command=['xcrun','swiftc','-swift-version','5','-module-cache-path',str(out/'modules')]
 if index==0: command+=['-parse-as-library']
 subprocess.run(command+[inputs[0],suite,'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
 print('MODEL_SUITE_PASS '+suite,flush=True)
assert hashes()==before
print(json.dumps({'inputHashes':before,'inputsUnchanged':True}),flush=True)
'''.replace('INPUTS', repr(inputs))
command = ['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(root),
    '--owner', os.environ.get('CODEX_THREAD_ID', 'ipad-ink-style-20261026'),
    '--job', 'ipad-ink-style-model-regressions', '--', 'python3', '-c', program]
result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
(output / 'runtime.log').write_text(result.stdout)
receipt = json.loads(result.stdout.strip().splitlines()[-1])
after = hashes()
passed = result.returncode == 0 and before == after and receipt.get('cleanup_verified') is True
(output / 'result.json').write_text(json.dumps(dict(inputHashes=before, afterHashes=after,
    inputsUnchanged=before == after, miniReceipt=receipt, exitCode=0 if passed else 1,
    sourceGuardVerified=False, scope='제품 모델의 좁은 독립 검사이며 작업 이전 수용 또는 UI 검증이 아닙니다.'), indent=2) + '\n')
print(result.stdout, end='')
sys.exit(0 if passed else 1)
