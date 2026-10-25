"""Owner-scoped ephemeral Mini execution and source/hash/cleanup receipts."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'CCR-Vision'], text=True))
ARCHIVE = Path(route['path']) / 'vision-native-gestures-20261026'
assert ARCHIVE.is_dir()
paths = ['iOSClient/StreamClient.swift','iOSClient/InputOverlay.swift','iOSClient/KeyChords.swift','iOSClient/SessionLink.swift','Sources/SillHost/KeyStrokes.swift','Sources/SillHost/SourceInputFence.swift','Tests/vision-pointer/main.swift','Tests/checks/fence/main.swift','Tests/checks/swift_platform.py']
for directory in ['visionOSClient','Sources/StreamProtocol','Tests/checks/vision-input-controls']:
    paths += [str(p.relative_to(ROOT)) for p in (ROOT / directory).rglob('*') if p.is_file() and p.suffix in {'.swift','.py','.json','.plist'} and not any(part.startswith('.') or part == '__pycache__' for part in p.relative_to(ROOT / directory).parts)]
paths = sorted(set(paths))
before = {p:hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
(ARCHIVE / 'worker-input-before.json').write_text(json.dumps(before, indent=2)+'\n')
with tempfile.TemporaryDirectory(prefix='native-input-', dir=ARCHIVE) as folder:
    temp=Path(folder)
    for p in paths:
        target=temp/p; target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(ROOT/p,target)
    (temp/'received-source-sha256.json').write_text(json.dumps(before))
    result=subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source','run','--source',str(temp),'--owner','01a13005-ff61-7780-b0e8-6dc171de1c9d','--job','vision-native-gestures-20261026','--','python3','-B','Tests/checks/vision-input-controls/native-run.py'],capture_output=True,text=True)
    log=result.stdout+result.stderr
    (ARCHIVE/'worker-result.log').write_text(log); print(log,end='')
after={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
(ARCHIVE/'worker-input-after.json').write_text(json.dumps(after,indent=2)+'\n');assert before==after
receipts=[json.loads(line) for line in result.stderr.splitlines() if line.startswith('{') and 'cleanup_verified' in line]
assert receipts and receipts[-1]['cleanup_verified']
(ARCHIVE/'worker-mini-receipt.json').write_text(json.dumps(receipts[-1],indent=2)+'\n')
raise SystemExit(result.returncode)
