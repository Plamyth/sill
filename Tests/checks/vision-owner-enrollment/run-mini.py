"""맥북 소스를 보존하고 작업 전용 Mini 입력·검사·삭제 영수증을 남긴다."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'CCR-Vision'], text=True))
ARCHIVE = Path(route['path']) / 'code-free-enrollment-20261026' / 'refusal-budget'
ARCHIVE.mkdir(exist_ok=True)
assert ARCHIVE.is_dir()
paths = ['iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Remote.swift', 'iOSClient/StreamClient+Home.swift',
    'iOSClient/OwnerBootstrapState.swift', 'iOSClient/OwnerBootstrapExchange.swift', 'iOSClient/RemoteConnector.swift',
    'iOSClient/RemoteDialPolicy.swift', 'iOSClient/DiscoveryPolicy.swift', 'iOSClient/SavedMacs.swift',
    'Scripts/make-vision-project.py', 'Scripts/provision-owner-bootstrap.py', 'SillVision.xcodeproj/project.pbxproj',
    'Tests/checks/swift_platform.py']
for directory in ['Sources/StreamProtocol', 'visionOSClient', 'iOSClient/Tests/owner-enrollment',
    'Tests/checks/vision-owner-enrollment', 'Tests/checks/vision-owner-bootstrap', 'Tests/checks/vision-autoconnect',
    'Tests/checks/vision-control-events', 'Tests/checks/owner-bootstrap-provision']:
    paths += [str(p.relative_to(ROOT)) for p in (ROOT / directory).rglob('*') if p.is_file() and p.suffix in {'.py', '.swift', '.json', '.plist'} and not any(part.startswith('.') or part == '__pycache__' for part in p.relative_to(ROOT / directory).parts)]
paths += ['iOSClient/' + n + '.swift' for n in ['IPadDeviceEnrollment', 'IPadEnrollmentJSON', 'IPadEnrollmentProtocol', 'IPadEnrollmentStore', 'IPadEnrollmentTransport', 'StreamClient+OwnerEnrollment']]
paths = sorted(set(paths))
hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
(ARCHIVE / 'worker-input-before.json').write_text(json.dumps(hashes, indent=2) + '\n')
with tempfile.TemporaryDirectory(prefix='worker-input-', dir=ARCHIVE) as folder:
    temp = Path(folder)
    for path in paths:
        target = temp / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, target)
    result = subprocess.run(['/Users/ambrion/.local/bin/mini-ephemeral-source', 'run', '--source', str(temp),
        '--owner', '01a13005-ff61-7780-b0e8-6dc171de1c9d', '--job', 'vision-enrollment-refusal-budget-20261026', '--',
        'python3', 'Tests/checks/vision-owner-enrollment/all.py'], capture_output=True, text=True)
    log = result.stdout + result.stderr
    (ARCHIVE / 'worker-result.log').write_text(log)
    print(log, end='')
after = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths}
(ARCHIVE / 'worker-input-after.json').write_text(json.dumps(after, indent=2) + '\n')
assert hashes == after
receipts = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{') and 'cleanup_verified' in line]
assert receipts and receipts[-1]['cleanup_verified'] is True
(ARCHIVE / 'worker-mini-receipt.json').write_text(json.dumps(receipts[-1], indent=2) + '\n')
raise SystemExit(result.returncode)
