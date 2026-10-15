import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
out = ROOT / 'Tests/checks/reconnect-glue/receipts'
label = sys.argv[1]
if (out / (label + '.json')).exists():
    raise SystemExit('reconcile existing build receipt before another attempt')
names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
paths = [ROOT / n for n in names if n and not n.startswith(('Tests/', 'docs/')) and (ROOT / n).is_file()]
sha = lambda b: hashlib.sha256(b).hexdigest()
hashes = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
command = ['xcodebuild', '-project', 'SillVision.xcodeproj', '-scheme', 'SillVision', '-configuration', 'Release', '-sdk', 'xros', '-destination', 'generic/platform=visionOS', '-derivedDataPath', str(ROOT / '.build/vision-reconnect'), '-jobs', '1', 'CODE_SIGNING_ALLOWED=NO', 'SWIFT_COMPILATION_MODE=wholemodule', 'SWIFT_MAXIMUM_PARALLEL_COMPILE_TASKS=1', 'SWIFT_ENABLE_BATCH_MODE=NO', 'OTHER_SWIFT_FLAGS=$(inherited) -num-threads 1', 'build']
start = time.time()
with (out / (label + '.log')).open('wb') as log:
    child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = child.wait(timeout=900)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            code = child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            code = child.wait(timeout=15)
record = {'command': command, 'developerDir': env['DEVELOPER_DIR'], 'xcode': subprocess.check_output(['xcodebuild', '-version'], env=env, text=True).strip(), 'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'sourceSHA256': hashes, 'sourceUnchanged': all(sha((ROOT / n).read_bytes()) == h for n, h in hashes.items()), 'compilerPID': child.pid, 'compilerReaped': child.poll() is not None, 'exitCode': code, 'elapsedSeconds': round(time.time() - start, 1), 'unsigned': True, 'scope': 'Exact local candidate XROS compilation only. No signing, installation, or device acceptance.'}
(out / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k != 'sourceSHA256'}, indent=2))
sys.exit(code)
